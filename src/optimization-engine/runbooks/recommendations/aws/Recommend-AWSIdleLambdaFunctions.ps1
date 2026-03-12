param(
  [Parameter(Mandatory = $false)]
  [string] $env = 'IGMF-Common-Services',

  [Parameter(Mandatory = $false)]
  # Use YYYY-MM-DD to lock to a specific export (idle_lambda_functions_YYYYMMDD-HHMMSS.csv)
  [string] $dateStamp
) 

$ErrorActionPreference = 'Stop'

# ===================== Config (Standardized) =====================
$cloudEnvironment           = Get-AutomationVariable -Name 'AzureOptimization_CloudEnvironment'
if (-not $cloudEnvironment) { $cloudEnvironment = 'AzureCloud' }

$workspaceId                = Get-AutomationVariable -Name 'AzureOptimization_LogAnalyticsWorkspaceId'
$workspaceName              = Get-AutomationVariable -Name 'AzureOptimization_LogAnalyticsWorkspaceName'
$workspaceRG                = Get-AutomationVariable -Name 'AzureOptimization_LogAnalyticsWorkspaceRG'
$workspaceSubscriptionId    = Get-AutomationVariable -Name 'AzureOptimization_LogAnalyticsWorkspaceSubId'
$workspaceTenantId          = Get-AutomationVariable -Name 'AzureOptimization_LogAnalyticsWorkspaceTenantId'
$lognamePrefix              = Get-AutomationVariable -Name 'AzureOptimization_LogAnalyticsLogPrefix' -ErrorAction SilentlyContinue
if (-not $lognamePrefix) { $lognamePrefix = 'AzureOptimization' }
$deploymentDate             = (Get-AutomationVariable -Name 'AzureOptimization_DeploymentDate').Replace('"','')

$storageAccountSink         = Get-AutomationVariable -Name 'AzureOptimization_StorageSink'
$storageAccountSinkRG       = Get-AutomationVariable -Name 'AzureOptimization_StorageSinkRG'
$storageAccountSinkSubId    = Get-AutomationVariable -Name 'AzureOptimization_StorageSinkSubId' -ErrorAction SilentlyContinue

$recoContainer              = Get-AutomationVariable -Name 'AzureOptimization_RecommendationsContainer' -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($recoContainer)) { $recoContainer = 'recommendationsexports' }

$awsExportsContainer        = Get-AutomationVariable -Name 'AzureOptimization_AwsExportsContainer' -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($awsExportsContainer)) { $awsExportsContainer = 'awsexports' }

# ===================== Auth & Context =====================
$authenticationOption = Get-AutomationVariable -Name "AzureOptimization_AuthenticationOption" -ErrorAction SilentlyContinue
$uamiClientID = Get-AutomationVariable -Name "AzureOptimization_UAMIClientID" -ErrorAction SilentlyContinue

switch ($authenticationOption) {
    "UserAssignedManagedIdentity" {
        Connect-AzAccount -Identity -EnvironmentName $cloudEnvironment -AccountId $uamiClientID | Out-Null
        break
    }
    Default { #ManagedIdentity
        Connect-AzAccount -Identity -EnvironmentName $cloudEnvironment | Out-Null
        break
    }
}
Set-AzContext -SubscriptionId $workspaceSubscriptionId | Out-Null

$originalContext = Get-AzContext
$needAltSub = -not [string]::IsNullOrWhiteSpace($storageAccountSinkSubId) -and ($storageAccountSinkSubId -ne $workspaceSubscriptionId)

try {
  if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

  # Resolve Storage Account
  try {
    $sa = Get-AzStorageAccount -ResourceGroupName $storageAccountSinkRG -Name $storageAccountSink -ErrorAction Stop
  } catch {
    $sa = Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $storageAccountSink } | Select-Object -First 1
  }

  $saCtx = New-AzStorageContext -StorageAccountName $storageAccountSink -UseConnectedAccount -Environment $cloudEnvironment

  # ---------------------------------------------------------------------------------------------
  # STEP 1: Update Pattern to match your Lambda Bash script output
  # ---------------------------------------------------------------------------------------------
  $csvPattern = 'idle_lambda_functions_*'
  if (-not [string]::IsNullOrWhiteSpace($dateStamp)) {
    $cleanDate = $dateStamp.Replace('-', '')
    $csvPattern = "idle_lambda_functions_$cleanDate*"
  }

  $blobs = Get-AzStorageBlob -Container $awsExportsContainer -Context $saCtx | 
           Where-Object { $_.Name -like "$csvPattern.csv" } | 
           Sort-Object LastModified -Descending

  if (-not $blobs) { 
    Write-Warning "No Idle AWS Lambda Functions CSV found in container '$awsExportsContainer' matching pattern '$csvPattern.csv'. No recommendations can be created."
    return
  }

  $latestBlob = $blobs[0]
  $tempCsv = [System.IO.Path]::GetTempFileName() + '.csv'
  Get-AzStorageBlobContent -Blob $latestBlob.Name -Container $awsExportsContainer -Destination $tempCsv -Context $saCtx -Force | Out-Null

  Write-Output "Processing AWS Lambda Function export: $($latestBlob.Name)"

} finally {
  if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }
}

# ===================== Parse CSV =====================
$rows = Import-Csv -Path $tempCsv

# ===================== Helper Functions =====================

# STEP 2: Console URL logic for Lambda
function Get-AWSLambdaConsoleUrl {
  param([string]$FnName, [string]$Region)
  "https://$Region.console.aws.amazon.com/lambda/home?region=$Region#/functions/$FnName"
}

# STEP 3: Fit Score Logic for Lambda PC
function Get-FitScoreForLambda {
  param([double]$SavingsCAD, [double]$UtilizationPct)
  
  # # Logic:
  # # High savings + very low utilization (< 1%) = Max Score (5)
  # if ($SavingsCAD -gt 50 -and $UtilizationPct -lt 1.0) { return 5 }
  # if ($SavingsCAD -gt 50) { return 4 }
  # if ($SavingsCAD -gt 10) { return 3 }
  # return 2
  return 3
}

# ===================== Build recommendations =====================
$nowUtc    = (Get-Date).ToUniversalTime()
$timestamp = $nowUtc.ToString('yyyy-MM-ddTHH:mm:00.000Z')

$recommendations = foreach ($r in $rows) {
  
  # ---------------------------------------------------------------------------------------------
  # STEP 4: Map the specific columns from your Lambda Bash script
  # ---------------------------------------------------------------------------------------------
  $account                 = [string]$r.account
  $region                  = [string]$r.region
  $fnName                  = [string]$r.function_name
  $fnArn                   = [string]$r.function_arn
  $runtime                 = [string]$r.runtime
  $memoryMb                = [string]$r.memory_mb
  $timeoutSec              = [string]$r.timeout_seconds
  $lastModified            = [string]$r.last_modified
  
  # Configuration & Metrics
  $reservedConcurrency     = $r.reserved_concurrency -as [int]
  $provisionedConcurrency  = $r.provisioned_concurrency -as [int]
  $avgPcUtilization        = $r.avg_pc_utilization_pct -as [double]
  $totalInvocations        = $r.total_invocations_30d -as [long]
  $avgInvocationsDay       = $r.avg_invocations_per_day -as [double]
  $recommendedPcSetting    = $r.recommended_pc_setting -as [int]
  
  # Financials
  $currentCostUSD          = $r.current_monthly_pc_cost_usd -as [double]
  $currentCostCAD          = $r.current_monthly_pc_cost_cad -as [double]
  $estimatedSavingsUSD     = $r.estimated_savings_usd -as [double]
  $estimatedSavingsCAD     = $r.estimated_savings_cad -as [double]
  
  $tags_raw                = [string]$r.tags 

  # Tag Parsing
  $tags = @{}
  if ($tags_raw) {
    $s = [string]$tags_raw
    $s = $s.Trim()
    if ($s.StartsWith('@{')) { $s = $s.Substring(2) }
    if ($s.EndsWith('}'))   { $s = $s.Substring(0, $s.Length - 1) }
    foreach ($pair in $s.Split(';')) {
      $kv = $pair.Split('=', 2)
      if ($kv.Count -eq 2) {
        $k = $kv[0].Trim()
        $v = $kv[1].Trim()
        if ($k) { $tags[$k] = $v }
      }
    }
  }
  
  # Build impact assessment
  $impact = if ($estimatedSavingsCAD -gt 100) { 'High' } elseif ($estimatedSavingsCAD -gt 50) { 'Medium' } else { 'Low' }
  
  # Description Generation
  $recDescription = "Lambda function has unused Provisioned Concurrency."
  $recActionText = "Remove Provisioned Concurrency configuration."
  
  if ($recommendedPcSetting -eq 0) {
      $recDescription = "Provisioned Concurrency is underutilized (< 5%)."
      $recActionText = "Remove Provisioned Concurrency to save fixed hourly costs."
  } else {
      # Fallback if you implement "reduction" logic later
      $recDescription = "Provisioned Concurrency is higher than required."
      $recActionText = "Reduce Provisioned Concurrency to $recommendedPcSetting."
  }

  # ---------------------------------------------------------------------------------------------
  # STEP 5: Create the Additional Info hash
  # ---------------------------------------------------------------------------------------------
  $additional = @{
    Account                = $account
    Region                 = $region
    FunctionName           = $fnName
    FunctionArn            = $fnArn
    Runtime                = $runtime
    MemoryMB               = $memoryMb
    TimeoutSeconds         = $timeoutSec
    LastModified           = $lastModified
    ProvisionedConcurrency = $provisionedConcurrency
    AvgPcUtilizationPct    = $avgPcUtilization
    TotalInvocations30d    = $totalInvocations
    AvgInvocationsPerDay   = $avgInvocationsDay
    CurrentCostUSD         = $currentCostUSD
    CostsAmount            = $currentCostCAD
    savingsAmount          = $estimatedSavingsCAD
    SavingsUSD             = $estimatedSavingsUSD
    Recommendation         = "Remove Provisioned Concurrency"
    Tags                   = $tags
    Signal                 = "Provisioned Concurrency Utilization < 5%"
    EstimationMethod       = "30-day CloudWatch metrics + FOCUS billing data aggregation"
  }
  
  $detailsUrl = Get-AWSLambdaConsoleUrl -FnName $fnName -Region $region

  [pscustomobject]@{
    Timestamp                 = $timestamp
    Cloud                     = 'AWS'
    Category                  = 'Cost'
    ImpactedArea              = 'lambda.function'
    Impact                    = $impact
    RecommendationType        = 'Saving'
    RecommendationSubType     = 'IdleLambdaProvisionedConcurrency'
    RecommendationSubTypeId   = '38c3bf86-45ed-440a-8e1f-f21184f28b60'
    RecommendationDescription = $recDescription
    RecommendationAction      = $recActionText
    InstanceId                = $fnArn
    InstanceName              = $fnName
    AdditionalInfo            = $additional
    ResourceGroup             = ''                
    SubscriptionGuid          = ''                 
    SubscriptionName          = $account          
    TenantGuid                = $workspaceTenantId
    FitScore                  = Get-FitScoreForLambda -SavingsCAD $estimatedSavingsCAD -UtilizationPct $avgPcUtilization
    Tags                      = $tags
    DetailsURL                = $detailsUrl
  }
}

# ===================== Export =====================
$fileDate = $nowUtc.ToString('yyyy-MM-dd')
# STEP 6: Update Output Filename
$outFile  = "aws-idle-lambda-functions-recommendations-$fileDate.json"

$recommendations | ConvertTo-Json | Out-File $outFile -Encoding utf8

if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

Set-AzStorageBlobContent -File $outFile -Container $recoContainer -Blob $outFile -Context $saCtx -Properties @{ 'ContentType' = 'application/json' } -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

Remove-Item $outFile -Force
Remove-Item $tempCsv -Force

$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Output "[$now] Exported $($recommendations.Count) AWS Idle Lambda Function recommendations to '$recoContainer/$outFile'."