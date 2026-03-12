param(
  [Parameter(Mandatory = $false)]
  [string] $env = 'IGMF-Common-Services',

  [Parameter(Mandatory = $false)]
  # Use YYYY-MM-DD to lock to a specific export (underutilized_load_balancers_YYYYMMDD-HHMMSS.csv)
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
  # STEP 1: Search for Load Balancer CSVs
  # ---------------------------------------------------------------------------------------------
  $csvPattern = 'underutilized_load_balancers_*'
  if (-not [string]::IsNullOrWhiteSpace($dateStamp)) {
    $cleanDate = $dateStamp.Replace('-', '')
    $csvPattern = "underutilized_load_balancers_$cleanDate*"
  }

  $blobs = Get-AzStorageBlob -Container $awsExportsContainer -Context $saCtx | 
           Where-Object { $_.Name -like "$csvPattern.csv" } | 
           Sort-Object LastModified -Descending

  if (-not $blobs) { 
    Write-Warning "No Underutilized AWS Load Balancers CSV found in container '$awsExportsContainer' matching pattern '$csvPattern.csv'. No recommendations can be created."
    return
  }

  $latestBlob = $blobs[0]
  $tempCsv = [System.IO.Path]::GetTempFileName() + '.csv'
  Get-AzStorageBlobContent -Blob $latestBlob.Name -Container $awsExportsContainer -Destination $tempCsv -Context $saCtx -Force | Out-Null

  Write-Output "Processing AWS Load Balancer export: $($latestBlob.Name)"

} finally {
  if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }
}

# ===================== Parse CSV =====================
$rows = Import-Csv -Path $tempCsv

# ===================== Helper Functions =====================

function Get-AWSLBConsoleUrl {
  param([string]$LbArn, [string]$Region)
  "https://$Region.console.aws.amazon.com/ec2/home?region=$Region#LoadBalancers:search=$LbArn"
}

function Get-FitScoreForLB {
  param([string]$Action, [double]$SavingsCAD, [int]$HealthyTargets)
  
  # if ($Action -eq 'remove') {
  #     if ($SavingsCAD -gt 50) { return 5 }
  #     if ($SavingsCAD -gt 10) { return 4 }
  #     return 3
  # }
  # elseif ($Action -eq 'consolidate') {
  #     if ($SavingsCAD -gt 100) { return 4 }
  #     return 3
  # }
  # return 2
  return 3
}

# ===================== Build recommendations =====================
$nowUtc    = (Get-Date).ToUniversalTime()
$timestamp = $nowUtc.ToString('yyyy-MM-ddTHH:mm:00.000Z')

$recommendations = foreach ($r in $rows) {
  
  $account                 = [string]$r.account
  $region                  = [string]$r.region
  $lbArn                   = [string]$r.load_balancer_arn
  $lbName                  = [string]$r.load_balancer_name
  $lbType                  = [string]$r.load_balancer_type
  $scheme                  = [string]$r.scheme
  $state                   = [string]$r.state
  $dnsName                 = [string]$r.dns_name
  $vpcId                   = [string]$r.vpc_id
  $healthyTargets          = $r.healthy_target_count -as [int]
  
  # Metrics
  $avgRequestsMin          = $r.avg_requests_per_min -as [double]
  $avgBytesSec             = $r.avg_processed_bytes_per_sec -as [double]
  
  # Financials
  $currentCostUSD          = $r.estimated_monthly_cost_usd -as [double]
  $currentCostCAD          = $r.estimated_monthly_cost_cad -as [double]
  $estimatedSavingsUSD     = $r.estimated_savings_usd -as [double]
  $estimatedSavingsCAD     = $r.estimated_savings_cad -as [double]
  $recommendationAction    = [string]$r.recommended_action
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
  
  $impact = if ($estimatedSavingsCAD -gt 100) { 'High' } elseif ($estimatedSavingsCAD -gt 50) { 'Medium' } else { 'Low' }
  
  # Descriptions
  $recDescription = "Load Balancer is underutilized."
  $recActionText = "Review load balancer configuration."
  
  if ($recommendationAction -eq 'remove') {
      $recDescription = "Load Balancer has 0 healthy targets and appears unused."
      $recActionText = "Delete this Load Balancer to stop incurring hourly charges."
  } elseif ($recommendationAction -eq 'consolidate') {
      $recDescription = "Load Balancer has very low traffic (< 1 req/min or < 100KB/s)."
      $recActionText = "Consider consolidating these targets onto another Load Balancer."
  }

  $additional = @{
    Account                = $account
    Region                 = $region
    LoadBalancerName       = $lbName
    LoadBalancerArn        = $lbArn
    LoadBalancerType       = $lbType
    Scheme                 = $scheme
    State                  = $state
    VpcId                  = $vpcId
    HealthyTargetCount     = $healthyTargets
    AvgRequestsPerMin      = $avgRequestsMin
    AvgProcessedBytesPerSec= $avgBytesSec
    CurrentCostUSD         = $currentCostUSD
    CostsAmount            = $currentCostCAD
    savingsAmount          = $estimatedSavingsCAD
    SavingsUSD             = $estimatedSavingsUSD
    Recommendation         = $recommendationAction
    Tags                   = $tags
    Signal                 = "Zero healthy targets OR Low Traffic (<1 req/min)"
    EstimationMethod       = "30-day CloudWatch metrics + FOCUS billing data aggregation"
  }
  
  $detailsUrl = Get-AWSLBConsoleUrl -LbArn $lbArn -Region $region

  [pscustomobject]@{
    Timestamp                 = $timestamp
    Cloud                     = 'AWS'
    Category                  = 'Cost'
    ImpactedArea              = 'elasticloadbalancing.loadbalancer'
    Impact                    = $impact
    RecommendationType        = 'Saving'
    RecommendationSubType     = 'UnderutilizedLoadBalancer'
    RecommendationSubTypeId   = '40ce15d4-250f-4fcf-9de5-a3392c00fceb'
    RecommendationDescription = $recDescription
    RecommendationAction      = $recActionText
    InstanceId                = $lbArn
    InstanceName              = $lbName
    AdditionalInfo            = $additional
    ResourceGroup             = ''                
    SubscriptionGuid          = ''                 
    SubscriptionName          = $account          
    TenantGuid                = $workspaceTenantId
    FitScore                  = Get-FitScoreForLB -Action $recommendationAction -SavingsCAD $estimatedSavingsCAD -HealthyTargets $healthyTargets
    Tags                      = $tags
    DetailsURL                = $detailsUrl
  }
}

# ===================== Export =====================
$fileDate = $nowUtc.ToString('yyyy-MM-dd')
$outFile  = "aws-underutilized-load-balancers-recommendations-$fileDate.json"

$recommendations | ConvertTo-Json | Out-File $outFile -Encoding utf8

if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

Set-AzStorageBlobContent -File $outFile -Container $recoContainer -Blob $outFile -Context $saCtx -Properties @{ 'ContentType' = 'application/json' } -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

Remove-Item $outFile -Force
Remove-Item $tempCsv -Force

$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Output "[$now] Exported $($recommendations.Count) AWS underutilized Load Balancer recommendations to '$recoContainer/$outFile'."