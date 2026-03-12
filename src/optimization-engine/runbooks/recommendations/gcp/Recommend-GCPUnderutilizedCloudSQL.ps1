param(
  [Parameter(Mandatory = $false)]
  [string] $env = 'IGMF-Common-Services',

  [Parameter(Mandatory = $false)]
  # Use YYYY-MM-DD to lock to a specific export (gcp-underutilized-cloudsql-YYYY-MM-DD.csv)
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

# Container holding the CSV exported by your Bash runbook
$gcpExportsContainer        = Get-AutomationVariable -Name 'AzureOptimization_GcpExportsContainer' -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($gcpExportsContainer)) { $gcpExportsContainer = 'gcpexports' }
# $recoContainer = 'recommendationstest'
# $gcpExportsContainer = 'gcptest'
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
    $sa = Get-AzStorageAccount -Name $storageAccountSink -ErrorAction Stop
    $storageAccountSinkRG = $sa.ResourceGroupName
  }

  $saCtx = New-AzStorageContext -StorageAccountName $storageAccountSink -UseConnectedAccount -Environment $cloudEnvironment
}
finally {
  if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }
}

# ===================== Locate latest CSV (same blob pattern style) =====================
# Expected columns in CSV: "project","instanceName","databaseVersion","currentTier","targetTier","region","instanceState","backendType","availabilityType","underutilizationReason","cpuAvgPercent","memoryAvgPercent","currentPriceUSDMonth","targetPriceUSDMonth","actualCostNet","actualCostCAD","actualCostCurrency","actualCostLookbackDays","monthlySavingsUSD","monthlySavingsCAD","grossCost","creditsAmount","creationTimestamp","instanceLabels"
$pattern = if ($dateStamp) { "gcp-underutilized-cloudsql-$dateStamp.csv" } else { "gcp-underutilized-cloudsql-*.csv" }

# Blob list/reads must use the subscription holding the storage account
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

$blobs = Get-AzStorageBlob -Context $saCtx -Container $gcpExportsContainer | Where-Object { $_.Name -like $pattern }

if (-not $blobs) {
  Write-Warning "No GCP Underutilized Cloud SQL CSV found in container '$gcpExportsContainer' matching pattern '$pattern'. No recommendation will be created."
  return
}

$targetBlob = if ($dateStamp) { $blobs | Select-Object -First 1 } else { $blobs | Sort-Object LastModified -Descending | Select-Object -First 1 }
$tempCsv = Join-Path $env:TEMP $targetBlob.Name
Get-AzStorageBlobContent -Context $saCtx -Container $gcpExportsContainer -Blob $targetBlob.Name -Destination $tempCsv -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# ===================== Import & filter (same style) =====================
$raw  = Import-Csv -LiteralPath $tempCsv

# Validate minimal fields - CSV already contains only underutilized instances
$rows = $raw | Where-Object {
  (-not [string]::IsNullOrWhiteSpace($_.project)) -and
  (-not [string]::IsNullOrWhiteSpace($_.instanceName)) -and
  (-not [string]::IsNullOrWhiteSpace($_.targetTier)) -and
  ($null -ne ($_.monthlySavingsCAD -as [double]))
}

Write-Output ("Rows after validation: {0}/{1}" -f $rows.Count, $raw.Count)
if ($rows.Count -eq 0) {
  Remove-Item $tempCsv -Force
  Write-Warning 'No qualifying rows to recommend after filtering.'
  return
}

# ===================== Helpers =====================
function New-GcpCloudSQLDeepLink {
  param([string]$Project, [string]$InstanceName)
  
  "https://console.cloud.google.com/sql/instances/$InstanceName/overview?project=$Project"
}

function Get-FitScoreForCloudSQL {
  param([string]$CurrentTier, [double]$SavingsCAD)
  # Higher fit score for higher-tier instances and higher savings
  if ($CurrentTier -match 'highmem|highcpu') {
    if ($SavingsCAD -gt 500) { return 5 } else { return 4 }
  }
  elseif ($CurrentTier -match 'standard') {
    if ($SavingsCAD -gt 200) { return 4 } else { return 3 }
  }
  else {
    if ($SavingsCAD -gt 50) { return 3 } else { return 2 }
  }
}

function New-ResourceDeepLink {
  param([string]$InstanceId, [string]$CloudEnv, [string]$TenantId)
  return $null
}

# ===================== Build recommendations =====================
$nowUtc    = (Get-Date).ToUniversalTime()
$timestamp = $nowUtc.ToString('yyyy-MM-ddTHH:mm:00.000Z')

$recommendations = foreach ($r in $rows) {
  $project             = [string]$r.project
  $instanceName        = [string]$r.instanceName
  $databaseVersion     = [string]$r.databaseVersion
  $currentTier         = [string]$r.currentTier
  $targetTier          = [string]$r.targetTier
  $region              = [string]$r.region
  $instanceState       = [string]$r.instanceState
  $backendType         = [string]$r.backendType
  $availabilityType    = [string]$r.availabilityType
  $reason              = [string]$r.underutilizationReason
  $cpuAvg              = $r.cpuAvgPercent -as [double]
  $memoryAvg           = $r.memoryAvgPercent -as [double]
  $currentPriceUSD     = $r.currentPriceUSDMonth -as [double]
  $targetPriceUSD      = $r.targetPriceUSDMonth -as [double]
  $actualCostNet       = $r.actualCostNet -as [double]
  $actualCostCAD       = $r.actualCostCAD -as [double]
  $actualCostCurrency  = [string]$r.actualCostCurrency
  $actualCostLookback  = $r.actualCostLookbackDays -as [int]
  $savingsUSD          = $r.monthlySavingsUSD -as [double]
  $savingsCAD          = $r.monthlySavingsCAD -as [double]
  $grossCost           = $r.grossCost -as [double]
  $creditsAmount       = $r.creditsAmount -as [double]
  $creationTimestamp   = [string]$r.creationTimestamp
  $labels              = [string]$r.instanceLabels
  $cloud               = if ($r.Cloud) { [string]$r.Cloud } else { 'GCP' }

  # parse Labels string into a dictionary (GCP Labels parsed as Tags)
  $tags = @{}
  if ($labels) {
    $s = [string]$labels
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

  $detailsUrl = New-GcpCloudSQLDeepLink -Project $project -InstanceName $instanceName
  $resourceId = "/projects/$project/instances/$instanceName"

  $impact = if ($savingsCAD -gt 400) { 'High' } elseif ($savingsCAD -gt 100) { 'Medium' } else { 'Low' }

  $additional = @{
    SourceCloud          = 'GCP'
    Project              = $project
    DatabaseVersion      = $databaseVersion
    CurrentTier          = $currentTier
    TargetTier           = $targetTier
    Region               = $region
    InstanceState        = $instanceState
    BackendType          = $backendType
    AvailabilityType     = $availabilityType
    UnderutilizationReason = $reason
    CPUAvgPercent        = $cpuAvg
    MemoryAvgPercent     = $memoryAvg
    CurrentPriceUSDMonth = $currentPriceUSD
    TargetPriceUSDMonth  = $targetPriceUSD
    ActualCostNet        = $actualCostNet
    ActualCostCAD        = $actualCostCAD
    ActualCostCurrency   = $actualCostCurrency
    ActualCostLookbackDays = $actualCostLookback
    CostsAmount          = $actualCostCAD
    savingsAmount        = $savingsCAD
    SavingsUSD           = $savingsUSD
    GrossCost            = $grossCost
    CreditsAmount        = $creditsAmount
    CreationTimestamp    = $creationTimestamp
    Labels               = $labels
    Signal               = $reason
    EstimationMethod     = "Average CPU/memory utilization with actual billing spend (lookback ${actualCostLookback}d) and regional pricing for downgrade recommendations"
  }

  [pscustomobject]@{
    Timestamp                 = $timestamp
    Cloud                     = 'GCP'
    Category                  = 'Cost'
    ImpactedArea              = 'sql.instances'
    Impact                    = $impact
    RecommendationType        = 'Saving'
    RecommendationSubType     = 'UnderutilizedDatabase'
    RecommendationSubTypeId   = '8506e717-041b-4744-b5fa-f0bf26e6c58e'
    RecommendationDescription = "Cloud SQL instance '$instanceName' is underutilized with $reason, and can be downsized from $currentTier to $targetTier for cost savings."
    RecommendationAction      = "Review workload requirements and consider downsizing the Cloud SQL instance from $currentTier to $targetTier. Monitor performance after change to ensure adequate resources."
    InstanceId                = $resourceId
    InstanceName              = $instanceName
    AdditionalInfo            = $additional
    ResourceGroup             = ''                # N/A for GCP
    SubscriptionGuid          = ''              # N/A for GCP
    SubscriptionName          = $project          # Overloaded with GCP Project for downstream processing
    TenantGuid                = $workspaceTenantId
    FitScore                  = Get-FitScoreForCloudSQL -CurrentTier $currentTier -SavingsCAD $savingsCAD
    Tags                      = $tags
    DetailsURL                = $detailsUrl
  }
}

# ===================== Export (same style) =====================
$fileDate = $nowUtc.ToString('yyyy-MM-dd')
$outFile  = "gcp-underutilized-cloudsql-recommendations-$fileDate.json"

$recommendations | ConvertTo-Json | Out-File $outFile -Encoding utf8

# Storage ops again happen in the storage sub if different
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

Set-AzStorageBlobContent -File $outFile -Container $recoContainer -Blob $outFile -Context $saCtx -Properties @{ 'ContentType' = 'application/json' } -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# Cleanup
Remove-Item $outFile -Force
Remove-Item $tempCsv -Force

$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Output "[$now] Exported $($recommendations.Count) GCP underutilized Cloud SQL recommendations to '$recoContainer/$outFile'."
