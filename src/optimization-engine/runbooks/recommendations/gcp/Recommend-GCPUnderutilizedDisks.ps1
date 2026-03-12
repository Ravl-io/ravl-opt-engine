param(
  [Parameter(Mandatory = $false)]
  [string] $env = 'IGMF-Common-Services',

  [Parameter(Mandatory = $false)]
  # Use YYYY-MM-DD to lock to a specific export (gcp-underutilized-disks-YYYY-MM-DD.csv)
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
# $gcpExportsContainer = 'gcptest'
# $recoContainer = 'recommendationstest'
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
# Expected columns in CSV (CAD export): "Project","Disk Name","Disk Type","Target Type","Disk Size GB","Zone","Region","Instance Name","Machine Type","Instance Status","Underutilization Reason","Average IOPS","Average Throughput MBps","Average Read Ops/Sec","Average Write Ops/Sec","Average Read Bytes/Sec","Average Write Bytes/Sec","Current Price CAD/GB/Month","Target Price CAD/GB/Month","Monthly Savings CAD","Monthly Savings USD","Monthly Cost CAD","Monthly Cost USD","Currency","Total Cost","Total Cost CAD","Gross Cost","Credits Amount","Creation Timestamp","Disk Labels"
$pattern = if ($dateStamp) { "gcp-underutilized-disks-$dateStamp.csv" } else { "gcp-underutilized-disks-*.csv" }

# Blob list/reads must use the subscription holding the storage account
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

$blobs = Get-AzStorageBlob -Context $saCtx -Container $gcpExportsContainer | Where-Object { $_.Name -like $pattern }
if (-not $blobs) {
  Write-Warning "No GCP Underutilized Disks CSV found in container '$gcpExportsContainer' matching pattern '$pattern'. No recommendation will be created."
  return
}

$targetBlob = if ($dateStamp) { $blobs | Select-Object -First 1 } else { $blobs | Sort-Object LastModified -Descending | Select-Object -First 1 }
$tempCsv = Join-Path $env:TEMP $targetBlob.Name
Get-AzStorageBlobContent -Context $saCtx -Container $gcpExportsContainer -Blob $targetBlob.Name -Destination $tempCsv -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# ===================== Import & filter (same style) =====================
$raw  = Import-Csv -LiteralPath $tempCsv

# Validate minimal fields - CSV already contains only underutilized disks
$rows = $raw | Where-Object {
  (-not [string]::IsNullOrWhiteSpace($_.Project)) -and
  (-not [string]::IsNullOrWhiteSpace($_.'Disk Name')) -and
  (-not [string]::IsNullOrWhiteSpace($_.'Target Type')) -and
  ($null -ne ($_.Currency)) -and
  ($_.PSObject.Properties['Monthly Savings CAD'] -or $_.PSObject.Properties['Monthly Savings USD'])
}

Write-Output ("Rows after validation: {0}/{1}" -f $rows.Count, $raw.Count)
if ($rows.Count -eq 0) {
  Remove-Item $tempCsv -Force
  Write-Warning 'No qualifying rows to recommend after filtering.'
  return
}

$colCurrentPrice = if ($rows[0].PSObject.Properties['Current Price CAD/GB/Month']) { 'Current Price CAD/GB/Month' } else { 'Current Price USD/GB/Month' }
$colTargetPrice  = if ($rows[0].PSObject.Properties['Target Price CAD/GB/Month'])  { 'Target Price CAD/GB/Month' }  else { 'Target Price USD/GB/Month' }
$colSavingsCad   = if ($rows[0].PSObject.Properties['Monthly Savings CAD']) { 'Monthly Savings CAD' } else { $null }
$colSavingsUsd   = if ($rows[0].PSObject.Properties['Monthly Savings USD']) { 'Monthly Savings USD' } else { $null }
$colMonthlyCostCad = if ($rows[0].PSObject.Properties['Monthly Cost CAD']) { 'Monthly Cost CAD' } else { $null }
$colMonthlyCostUsd = if ($rows[0].PSObject.Properties['Monthly Cost USD']) { 'Monthly Cost USD' } else { $null }
$colTotalCost    = if ($rows[0].PSObject.Properties['Total Cost']) { 'Total Cost' } else { $null }
$colTotalCostCad = if ($rows[0].PSObject.Properties['Total Cost CAD']) { 'Total Cost CAD' } else { $null }
$colGrossCost    = if ($rows[0].PSObject.Properties['Gross Cost']) { 'Gross Cost' } else { $null }
$colCredits      = if ($rows[0].PSObject.Properties['Credits Amount']) { 'Credits Amount' } else { $null }

# ===================== Helpers =====================
function New-GcpDiskDeepLink {
  param([string]$Project, [string]$Zone, [string]$DiskName)
  
  "https://console.cloud.google.com/compute/disksDetail/zones/$Zone/disks/$DiskName?project=$Project"
}

function Get-FitScoreForDisk {
  param([string]$DiskType, [double]$SavingsCAD, [double]$DiskSizeGB)
  # Higher fit score for higher-performance disks, larger disks, and higher savings
  if ($DiskType -eq 'pd-ssd') {
    if ($SavingsCAD -gt 100) { return 5 } elseif ($SavingsCAD -gt 50) { return 4 } else { return 3 }
  }
  elseif ($DiskType -eq 'pd-balanced') {
    if ($SavingsCAD -gt 50) { return 4 } elseif ($SavingsCAD -gt 20) { return 3 } else { return 2 }
  }
  else {
    if ($SavingsCAD -gt 20) { return 3 } else { return 2 }
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
  $project             = [string]$r.Project
  $diskName            = [string]$r.'Disk Name'
  $diskType            = [string]$r.'Disk Type'
  $targetType          = [string]$r.'Target Type'
  $diskSizeGB          = $r.'Disk Size GB' -as [double]
  $zone                = [string]$r.Zone
  $region              = [string]$r.Region
  $instanceName        = [string]$r.'Instance Name'
  $machineType         = [string]$r.'Machine Type'
  $instanceStatus      = [string]$r.'Instance Status'
  $reason              = [string]$r.'Underutilization Reason'
  $averageIOPS         = $r.'Average IOPS' -as [double]
  $averageThroughput   = $r.'Average Throughput MBps' -as [double]
  $averageReadOps      = $r.'Average Read Ops/Sec' -as [double]
  $averageWriteOps     = $r.'Average Write Ops/Sec' -as [double]
  $averageReadBytes    = $r.'Average Read Bytes/Sec' -as [double]
  $averageWriteBytes   = $r.'Average Write Bytes/Sec' -as [double]
  $currentPrice        = if ($colCurrentPrice) { $r.$colCurrentPrice -as [double] } else { $null }
  $targetPrice         = if ($colTargetPrice)  { $r.$colTargetPrice  -as [double] } else { $null }
  $savingsCAD          = if ($colSavingsCad)   { $r.$colSavingsCad   -as [double] } else { 0 }
  $savingsUSD          = if ($colSavingsUsd)   { $r.$colSavingsUsd   -as [double] } else { 0 }
  $monthlyCostCAD      = if ($colMonthlyCostCad) { $r.$colMonthlyCostCad -as [double] } else { $null }
  $monthlyCostUSD      = if ($colMonthlyCostUsd) { $r.$colMonthlyCostUsd -as [double] } else { $null }
  $currency            = [string]$r.Currency
  $totalCost           = if ($colTotalCost)    { $r.$colTotalCost    -as [double] } else { $null }
  $totalCostCAD        = if ($colTotalCostCad) { $r.$colTotalCostCad -as [double] } else { $null }
  $grossCost           = if ($colGrossCost)    { $r.$colGrossCost    -as [double] } else { $null }
  $creditsAmount       = if ($colCredits)      { $r.$colCredits      -as [double] } else { $null }
  $creationTimestamp   = [string]$r.'Creation Timestamp'
  $labels              = [string]$r.'Disk Labels'
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

  $detailsUrl = New-GcpDiskDeepLink -Project $project -Zone $zone -DiskName $diskName
  $resourceId = "/projects/$project/zones/$zone/disks/$diskName"

  $impact = if ($savingsCAD -gt 80) { 'High' } elseif ($savingsCAD -gt 30) { 'Medium' } else { 'Low' }

  $additional = @{
    SourceCloud            = 'GCP'
    Project                = $project
    DiskType               = $diskType
    TargetType             = $targetType
    DiskSizeGB             = $diskSizeGB
    Zone                   = $zone
    Region                 = $region
    InstanceName           = $instanceName
    MachineType            = $machineType
    InstanceStatus         = $instanceStatus
    UnderutilizationReason = $reason
    AverageIOPS            = $averageIOPS
    AverageThroughputMBps  = $averageThroughput
    AverageReadOpsPerSec   = $averageReadOps
    AverageWriteOpsPerSec  = $averageWriteOps
    AverageReadBytesPerSec = $averageReadBytes
    AverageWriteBytesPerSec = $averageWriteBytes
    CurrentPricePerGBMonth = $currentPrice
    TargetPricePerGBMonth  = $targetPrice
    MonthlyCostCAD         = $monthlyCostCAD
    MonthlyCostUSD         = $monthlyCostUSD
    Currency               = $currency
    TotalCost              = $totalCost
    TotalCostCAD           = $totalCostCAD
    GrossCost              = $grossCost
    CreditsAmount          = $creditsAmount
    CostsAmount            = $totalCostCAD
    savingsAmount          = $savingsCAD
    SavingsUSD             = $savingsUSD
    CreationTimestamp      = $creationTimestamp
    Labels                 = $labels
    Signal                 = $reason
    EstimationMethod       = "30-day IOPS and throughput analysis with regional disk pricing for tier downgrade recommendations"
  }

  [pscustomobject]@{
    Timestamp                 = $timestamp
    Cloud                     = 'GCP'
    Category                  = 'Cost'
    ImpactedArea              = 'compute.disks'
    Impact                    = $impact
    RecommendationType        = 'Saving'
    RecommendationSubType     = 'UnderutilizedDisk'
    RecommendationSubTypeId   = '61b3e9e3-0e00-4041-9b6e-6723b8ab34db'
    RecommendationDescription = "High-performance disk '$diskName' ($diskType) is underutilized with $reason, and can be downgraded to $targetType for cost savings."
    RecommendationAction      = "Consider downgrading disk '$diskName' from $diskType to $targetType to reduce costs. Ensure the lower performance tier meets workload requirements before making changes."
    InstanceId                = $resourceId
    InstanceName              = $diskName
    AdditionalInfo            = $additional
    ResourceGroup             = ''                # N/A for GCP
    SubscriptionGuid          = ''                # N/A for GCP
    SubscriptionName          = $project          # Overloaded with GCP Project for downstream processing
    TenantGuid                = $workspaceTenantId
    FitScore                  = Get-FitScoreForDisk -DiskType $diskType -SavingsCAD $savingsCAD -DiskSizeGB $diskSizeGB
    Tags                      = $tags
    DetailsURL                = $detailsUrl
  }
}

# ===================== Export (same style) =====================
$fileDate = $nowUtc.ToString('yyyy-MM-dd')
$outFile  = "gcp-underutilized-disks-recommendations-$fileDate.json"

$recommendations | ConvertTo-Json | Out-File $outFile -Encoding utf8

# Storage ops again happen in the storage sub if different
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

Set-AzStorageBlobContent -File $outFile -Container $recoContainer -Blob $outFile -Context $saCtx -Properties @{ 'ContentType' = 'application/json' } -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# Cleanup
Remove-Item $outFile -Force
Remove-Item $tempCsv -Force

$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Output "[$now] Exported $($recommendations.Count) GCP underutilized disk recommendations to '$recoContainer/$outFile'."
