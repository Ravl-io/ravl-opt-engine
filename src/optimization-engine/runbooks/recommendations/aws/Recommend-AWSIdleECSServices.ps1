param(
  [Parameter(Mandatory = $false)]
  [string] $env = 'IGMF-Common-Services',

  [Parameter(Mandatory = $false)]
  # Use YYYY-MM-DD to lock to a specific export (idle_ecs_services_YYYYMMDD-HHMMSS.csv)
  [string] $dateStamp
) 

$ErrorActionPreference = 'Stop'

# ===================== Config (same style as working runbook) =====================
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

# Container holding the CSV exported by AWS bash runbook
$awsExportsContainer        = Get-AutomationVariable -Name 'AzureOptimization_AwsExportsContainer' -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($awsExportsContainer)) { $awsExportsContainer = 'awsexports' }

# ===================== Auth & Context (same as working runbook) =====================
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

# Build a storage context. If storage is in a different subscription, switch just for storage ops.
$originalContext = Get-AzContext
$needAltSub = -not [string]::IsNullOrWhiteSpace($storageAccountSinkSubId) -and ($storageAccountSinkSubId -ne $workspaceSubscriptionId)

try {
  if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

  # Resolve Storage Account (fast-path with RG; fallback by name)
  try {
    $sa = Get-AzStorageAccount -ResourceGroupName $storageAccountSinkRG -Name $storageAccountSink -ErrorAction Stop
  } catch {
    # Fallback: search by name across subscription
    $sa = Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $storageAccountSink } | Select-Object -First 1
  }

  $saCtx = New-AzStorageContext -StorageAccountName $storageAccountSink -UseConnectedAccount -Environment $cloudEnvironment

  # Get the most recent CSV from the AWS exports container
  $csvPattern = 'idle_ecs_services_*'
  if (-not [string]::IsNullOrWhiteSpace($dateStamp)) {
    # Convert YYYY-MM-DD to YYYYMMDD format expected by AWS scripts
    $cleanDate = $dateStamp.Replace('-', '')
    $csvPattern = "idle_ecs_services_$cleanDate*"
  }

  $blobs = Get-AzStorageBlob -Container $awsExportsContainer -Context $saCtx | 
           Where-Object { $_.Name -like "$csvPattern.csv" } | 
           Sort-Object LastModified -Descending

  if (-not $blobs) { 
    Write-Warning "No Idle AWS ECS services CSV found in container '$awsExportsContainer' matching pattern '$csvPattern.csv'. No recommendations can be created."
    return
  }

  $latestBlob = $blobs[0]
  $tempCsv = [System.IO.Path]::GetTempFileName() + '.csv'
  Get-AzStorageBlobContent -Blob $latestBlob.Name -Container $awsExportsContainer -Destination $tempCsv -Context $saCtx | Out-Null

  Write-Output "Processing AWS ECS services export: $($latestBlob.Name)"

} finally {
  if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }
}

# ===================== Parse CSV =====================
$rows = Import-Csv -Path $tempCsv

# ===================== Helper Functions =====================
function Get-AWSECSConsoleUrl {
  param([string]$ClusterName, [string]$ServiceName, [string]$Region, [string]$Account)
  
  "https://$Region.console.aws.amazon.com/ecs/home?region=$Region#/clusters/$ClusterName/services/$ServiceName"
}

function Get-FitScoreForECSService {
  param([string]$ServiceName, [double]$SavingsCAD, [int]$TaskCount)
  # Higher fit score for services with more tasks and higher savings
  if ($TaskCount -ge 5) {
    if ($SavingsCAD -gt 500) { return 5 } elseif ($SavingsCAD -gt 250) { return 4 } else { return 3 }
  }
  elseif ($TaskCount -ge 2) {
    if ($SavingsCAD -gt 200) { return 4 } elseif ($SavingsCAD -gt 100) { return 3 } else { return 2 }
  }
  else {
    if ($SavingsCAD -gt 100) { return 3 } elseif ($SavingsCAD -gt 50) { return 2 } else { return 1 }
  }
}

function New-ResourceDeepLink {
  param([string]$ServiceName, [string]$CloudEnv, [string]$TenantId)
  return $null
}

# ===================== Build recommendations =====================
$nowUtc    = (Get-Date).ToUniversalTime()
$timestamp = $nowUtc.ToString('yyyy-MM-ddTHH:mm:00.000Z')

$recommendations = foreach ($r in $rows) {
  $account                 = [string]$r.account
  $region                  = [string]$r.region
  $clusterName             = [string]$r.cluster_name
  $serviceName             = [string]$r.service_name
  $taskDefinition          = [string]$r.task_definition
  $desiredCount            = $r.desired_count -as [int]
  $runningCount            = $r.running_count -as [int]
  $pendingCount            = $r.pending_count -as [int]
  $avgCpuUtilization       = $r.avg_cpu_utilization -as [double]
  $avgMemoryUtilization    = $r.avg_memory_utilization -as [double]
  $launchType              = [string]$r.launch_type
  $platformVersion         = [string]$r.platform_version
  $monthlyCostUSD          = $r.monthly_cost_usd -as [double]
  $monthlyCostCAD          = $r.monthly_cost_cad -as [double]
  $monthlySavingsUSD       = $r.monthly_savings_usd -as [double]
  $monthlySavingsCAD       = $r.monthly_savings_cad -as [double]
  $tags_raw                = [string]$r.tags

  # Parse tags string into a dictionary (AWS tags parsed as Tags)
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

  # Build resource identifiers
  $resourceId = "arn:aws:ecs:${region}:${account}:service/$clusterName/$serviceName"
  
  # Build impact assessment
  $impact = if ($monthlySavingsCAD -gt 500) { 'High' } elseif ($monthlySavingsCAD -gt 200) { 'Medium' } else { 'Low' }
  
  # Build additional info object
  $additional = @{
    Account                = $account
    Region                 = $region
    ClusterName            = $clusterName
    ServiceName            = $serviceName
    TaskDefinition         = $taskDefinition
    DesiredCount           = $desiredCount
    RunningCount           = $runningCount
    PendingCount           = $pendingCount
    AvgCpuUtilization      = $avgCpuUtilization
    AvgMemoryUtilization   = $avgMemoryUtilization
    LaunchType             = $launchType
    PlatformVersion        = $platformVersion
    MonthlyCostUSD         = $monthlyCostUSD
    MonthlyCostCAD         = $monthlyCostCAD
    CostsAmount            = $monthlySavingsCAD
    savingsAmount          = $monthlySavingsCAD
    SavingsUSD             = $monthlySavingsUSD
    Signal                 = "Low CPU and memory utilization with idle tasks"
    EstimationMethod       = "30-day CPU and memory analysis of ECS tasks for idle service identification"
  }
  
  # Build details URL
  $detailsUrl = Get-AWSECSConsoleUrl -ClusterName $clusterName -ServiceName $serviceName -Region $region -Account $account

  [pscustomobject]@{
    Timestamp                 = $timestamp
    Cloud                     = 'AWS'
    Category                  = 'Cost'
    ImpactedArea              = 'ecs.services'
    Impact                    = $impact
    RecommendationType        = 'Saving'
    RecommendationSubType     = 'IdleECSService'
    RecommendationSubTypeId   = 'b7c5a9e1-4d6f-4e2b-a8c7-9f1e3b5d8a42'
    RecommendationDescription = "ECS service is idle and can be optimized or terminated for cost savings."
    RecommendationAction      = "Consider reducing desired count or terminating idle ECS service. Verify service requirements before making changes."
    InstanceId                = $resourceId
    InstanceName              = $serviceName
    AdditionalInfo            = $additional
    ResourceGroup             = ''                # N/A for AWS
    SubscriptionGuid          = ''                # N/A for AWS  
    SubscriptionName          = $account          # Overloaded with AWS Account for downstream processing
    TenantGuid                = $workspaceTenantId
    FitScore                  = Get-FitScoreForECSService -ServiceName $serviceName -SavingsCAD $monthlySavingsCAD -TaskCount $runningCount
    Tags                      = $tags
    DetailsURL                = $detailsUrl
  }
}

# ===================== Export (same style) =====================
$fileDate = $nowUtc.ToString('yyyy-MM-dd')
$outFile  = "aws-idle-ecs-services-recommendations-$fileDate.json"

$recommendations | ConvertTo-Json | Out-File $outFile -Encoding utf8

# Storage ops again happen in the storage sub if different
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

Set-AzStorageBlobContent -File $outFile -Container $recoContainer -Blob $outFile -Context $saCtx -Properties @{ 'ContentType' = 'application/json' } -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# Cleanup
Remove-Item $outFile -Force
Remove-Item $tempCsv -Force

$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Output "[$now] Exported $($recommendations.Count) AWS idle ECS service recommendations to '$recoContainer/$outFile'."