param(
  [Parameter(Mandatory = $false)]
  [string] $env = 'IGMF-Common-Services',

  [Parameter(Mandatory = $false)]
  # Use YYYY-MM-DD to lock to a specific export (idle_elastic_beanstalk_environments_YYYYMMDD-HHMMSS.csv)
  [string] $dateStamp
) 

$ErrorActionPreference = 'Stop'

# ===================== Config =====================
$cloudEnvironment           = Get-AutomationVariable -Name 'AzureOptimization_CloudEnvironment'
if (-not $cloudEnvironment) { $cloudEnvironment = 'AzureCloud' }

$workspaceId                = Get-AutomationVariable -Name 'AzureOptimization_LogAnalyticsWorkspaceId'
$workspaceSubscriptionId    = Get-AutomationVariable -Name 'AzureOptimization_LogAnalyticsWorkspaceSubId'
$workspaceTenantId          = Get-AutomationVariable -Name 'AzureOptimization_LogAnalyticsWorkspaceTenantId'

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

  # Get the most recent CSV matching the EB pattern
  $csvPattern = 'idle_elastic_beanstalk_environments_*'
  if (-not [string]::IsNullOrWhiteSpace($dateStamp)) {
    $cleanDate = $dateStamp.Replace('-', '')
    $csvPattern = "idle_elastic_beanstalk_environments_$cleanDate*"
  }

  $blobs = Get-AzStorageBlob -Container $awsExportsContainer -Context $saCtx | 
           Where-Object { $_.Name -like "$csvPattern.csv" } | 
           Sort-Object LastModified -Descending

  if (-not $blobs) { 
      Write-Warning "No Idle AWS Elastic Beanstalk Environments CSV found in container '$awsExportsContainer' matching pattern '$csvPattern.csv'. No recommendations can be created."
      return
    }

  $latestBlob = $blobs[0]
  $tempCsv = [System.IO.Path]::GetTempFileName() + '.csv'
  Get-AzStorageBlobContent -Blob $latestBlob.Name -Container $awsExportsContainer -Destination $tempCsv -Context $saCtx -Force | Out-Null

  Write-Output "Processing AWS Elastic Beanstalk export: $($latestBlob.Name)"

} finally {
  if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }
}

# ===================== Parse CSV =====================
$rows = Import-Csv -Path $tempCsv

# ===================== Helper Functions =====================
function Get-AWSEBConsoleUrl {
  param([string]$EnvId, [string]$Region)
  "https://$Region.console.aws.amazon.com/elasticbeanstalk/home?region=$Region#/environment/dashboard?environmentId=$EnvId"
}

function Get-FitScoreForEB {
  param([double]$SavingsCAD, [double]$RequestsPerMin, [double]$CpuPct)
  
  # # Logic: High savings + extremely low traffic/CPU = Max Score
  # if ($RequestsPerMin -lt 0.1 -and $CpuPct -lt 1.0 -and $SavingsCAD -gt 50) { return 5 }
  # if ($SavingsCAD -gt 50) { return 4 }
  # if ($SavingsCAD -gt 10) { return 3 }
  # return 2
  return 3
}

# ===================== Build recommendations =====================
$nowUtc    = (Get-Date).ToUniversalTime()
$timestamp = $nowUtc.ToString('yyyy-MM-ddTHH:mm:00.000Z')

$recommendations = foreach ($r in $rows) {
  $account                 = [string]$r.account
  $region                  = [string]$r.region
  $envName                 = [string]$r.environment_name
  $appName                 = [string]$r.application_name
  $envId                   = [string]$r.environment_id
  $status                  = [string]$r.status
  $health                  = [string]$r.health
  $envType                 = [string]$r.environment_type
  $instanceType            = [string]$r.instance_type
  $instanceCount           = $r.instance_count -as [int]
  
  # Metrics
  $avgCpu                  = $r.avg_cpu_utilization_pct -as [double]
  $avgRequests             = $r.avg_requests_per_min -as [double]
  $avgNetIn                = $r.avg_network_in_mb_per_s -as [double]
  $avgNetOut               = $r.avg_network_out_mb_per_s -as [double]
  
  # Financials
  $currentCostUSD          = $r.current_estimated_cost_usd_month -as [double]
  $currentCostCAD          = $r.current_estimated_cost_cad_month -as [double]
  $estimatedSavingsUSD     = $r.estimated_savings_usd -as [double]
  $estimatedSavingsCAD     = $r.estimated_savings_cad -as [double]
  $recommendation          = [string]$r.recommended_action
  $tags_raw                = [string]$r.tags

  # Parse Tags
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

  # Build identifiers
  $resourceId = "arn:aws:elasticbeanstalk:${region}:${account}:environment/$appName/$envName"
  
  # Build impact assessment
  $impact = if ($estimatedSavingsCAD -gt 100) { 'High' } elseif ($estimatedSavingsCAD -gt 50) { 'Medium' } else { 'Low' }
  
  # Build additional info
  $additional = @{
    Account                = $account
    Region                 = $region
    EnvironmentName        = $envName
    EnvironmentId          = $envId
    ApplicationName        = $appName
    Status                 = $status
    Health                 = $health
    EnvironmentType        = $envType
    InstanceType           = $instanceType
    InstanceCount          = $instanceCount
    AvgCpuUtilization      = $avgCpu
    AvgRequestsPerMin      = $avgRequests
    AvgNetworkInMB         = $avgNetIn
    AvgNetworkOutMB        = $avgNetOut
    CurrentCostUSD         = $currentCostUSD
    CostsAmount            = $currentCostCAD
    savingsAmount          = $estimatedSavingsCAD
    SavingsUSD             = $estimatedSavingsUSD
    Recommendation         = $recommendation
    Tags                   = $tags
    Signal                 = "Low CPU (<5%) and Requests (<1/min)"
    EstimationMethod       = "30-day CloudWatch metrics + FOCUS billing data aggregation"
  }
  
  $detailsUrl = Get-AWSEBConsoleUrl -EnvId $envId -Region $region

  [pscustomobject]@{
    Timestamp                 = $timestamp
    Cloud                     = 'AWS'
    Category                  = 'Cost'
    ImpactedArea              = 'elasticbeanstalk.environment'
    Impact                    = $impact
    RecommendationType        = 'Saving'
    RecommendationSubType     = 'IdleElasticBeanstalkEnvironment'
    RecommendationSubTypeId   = 'ee605651-338d-4d60-becb-e58962dddc00'
    RecommendationDescription = "Elastic Beanstalk environment appears idle (low CPU and network traffic)."
    RecommendationAction      = "Decommission this environment or stop the underlying instances to save costs."
    InstanceId                = $resourceId
    InstanceName              = $envName
    AdditionalInfo            = $additional
    ResourceGroup             = ''                
    SubscriptionGuid          = ''                 
    SubscriptionName          = $account          
    TenantGuid                = $workspaceTenantId
    FitScore                  = Get-FitScoreForEB -SavingsCAD $estimatedSavingsCAD -RequestsPerMin $avgRequests -CpuPct $avgCpu
    Tags                      = $tags
    DetailsURL                = $detailsUrl
  }
}

# ===================== Export =====================
$fileDate = $nowUtc.ToString('yyyy-MM-dd')
$outFile  = "aws-idle-elastic-beanstalk-recommendations-$fileDate.json"

$recommendations | ConvertTo-Json | Out-File $outFile -Encoding utf8

# Switch to storage context if needed
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

Set-AzStorageBlobContent -File $outFile -Container $recoContainer -Blob $outFile -Context $saCtx -Properties @{ 'ContentType' = 'application/json' } -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# Cleanup
Remove-Item $outFile -Force
Remove-Item $tempCsv -Force

$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Output "[$now] Exported $($recommendations.Count) AWS idle Elastic Beanstalk recommendations to '$recoContainer/$outFile'."