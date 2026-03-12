param(
  [Parameter(Mandatory = $false)]
  [string] $env = 'IGMF-Common-Services',

  [Parameter(Mandatory = $false)]
  # Use YYYYMMDD-HHMMSS to lock to a specific export (gcp-underutilized-vms-offhours-<timestamp>.csv)
  [string] $dateStamp
)

$ErrorActionPreference = 'Stop'

# ===================== Config =====================
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

$gcpExportsContainer        = Get-AutomationVariable -Name 'AzureOptimization_GcpExportsContainer' -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($gcpExportsContainer)) { $gcpExportsContainer = 'gcpexports' }

# $gcpExportsContainer = 'gcptest'
# $recoContainer = 'recommendationstest'
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

# ===================== Locate latest CSV =====================
$pattern = if ($dateStamp) { "gcp-underutilized-vms-offhours-$dateStamp.csv" } else { "gcp-underutilized-vms-offhours-*.csv" }

if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }
$blobs = Get-AzStorageBlob -Context $saCtx -Container $gcpExportsContainer | Where-Object { $_.Name -like $pattern }
if (-not $blobs) {
  Write-Warning "No GCP Underutilized VMs Off Hours CSV found in container '$gcpExportsContainer' matching pattern '$pattern'. No recommendation will be created."
  return
}
$targetBlob = if ($dateStamp) { $blobs | Select-Object -First 1 } else { $blobs | Sort-Object LastModified -Descending | Select-Object -First 1 }
$tempCsv = Join-Path $env:TEMP $targetBlob.Name
Get-AzStorageBlobContent -Context $saCtx -Container $gcpExportsContainer -Blob $targetBlob.Name -Destination $tempCsv -Force | Out-Null
if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# ===================== Import & filter =====================
$raw  = Import-Csv -LiteralPath $tempCsv
$rows = $raw | Where-Object {
  ($_.PSObject.Properties['ProjectID']) -and
  ($_.PSObject.Properties['VMName']) -and
  ($_.PSObject.Properties['Zone']) -and
  ($_.PSObject.Properties['MachineType']) -and
  ($_.PSObject.Properties['PotentialOffHoursSavingsCAD'])
}
Write-Output ("Rows after validation: {0}/{1}" -f $rows.Count, $raw.Count)
if ($rows.Count -eq 0) {
  Remove-Item $tempCsv -Force
  Write-Warning 'No qualifying rows to recommend after filtering.'
  return
}

# ===================== Helpers =====================
function Convert-GcpLabelsToHash {
  param([string]$Labels)
  $tags = @{}
  if (-not $Labels) { return $tags }
  $s = $Labels.Trim()
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
  return $tags
}

function New-GcpVmDeepLink {
  param([string]$Project,[string]$Zone,[string]$Name)
  "https://console.cloud.google.com/compute/instancesDetail/zones/$Zone/instances/$Name?project=$Project"
}

# ===================== Build recommendations =====================
$nowUtc    = (Get-Date).ToUniversalTime()
$timestamp = $nowUtc.ToString('yyyy-MM-ddTHH:mm:00.000Z')

$recommendations = foreach ($r in $rows) {
  $project     = [string]$r.ProjectID
  $vmName      = [string]$r.VMName
  $zone        = [string]$r.Zone
  $machineType = [string]$r.MachineType
  $avgUtil     = $r.AvgMaxOffHoursUtilization -as [double]
  $currency    = if ($r.Currency) { [string]$r.Currency } else { 'CAD' }
  $totalCost   = $r.TotalCost -as [double]
  $totalCostCAD= $r.TotalCostCAD -as [double]
  $savingsCAD  = $r.PotentialOffHoursSavingsCAD -as [double]
  $savingsUSD  = $r.PotentialOffHoursSavings -as [double]
  $grossCost   = $r.GrossCost -as [double]
  $credits     = $r.CreditsAmount -as [double]
  $labels      = [string]$r.Labels
  $tags        = Convert-GcpLabelsToHash -Labels $labels
  $impact = if ($savingsCAD -gt 100) { 'High' } elseif ($savingsCAD -gt 40) { 'Medium' } else { 'Low' }
  $detailsUrl = New-GcpVmDeepLink -Project $project -Zone $zone -Name $vmName
  $resourceId = "/projects/$project/zones/$zone/instances/$vmName"

  $additional = @{
    SourceCloud              = 'GCP'
    Project                  = $project
    Zone                     = $zone
    MachineType              = $machineType
    AvgMaxOffHoursUtilization= $avgUtil
    Currency                 = $currency
    TotalCost                = $totalCost
    TotalCostCAD             = $totalCostCAD
    PotentialOffHoursSavings = $savingsUSD
    PotentialOffHoursSavingsCAD = $savingsCAD
    GrossCost                = $grossCost
    CreditsAmount            = $credits
    Labels                   = $labels
    CostsAmount              = $totalCostCAD
    savingsAmount            = $savingsCAD
  }

  [pscustomobject]@{
    Timestamp                 = $timestamp
    Cloud                     = 'GCP'
    Category                  = 'Cost'
    ImpactedArea              = 'compute.instances'
    Impact                    = $impact
    RecommendationType        = 'Saving'
    RecommendationSubType     = 'UnderutilizedOffHours'
    RecommendationSubTypeId   = '64648faa-c459-404e-baf0-bdbf5199e628'
    RecommendationDescription = 'GCP underutilized VM detected with potential savings during off-hours. Consider automating deallocation during off-hours(6PM-8AM Weekdays, 24H Weekends) using start/stop schedules to reduce costs.'
    RecommendationAction      = 'Automate deallocation during off-hours (start/stop schedule).'
    InstanceId                = $resourceId
    InstanceName              = $vmName
    AdditionalInfo            = $additional
    ResourceGroup             = ''                # N/A for GCP
    SubscriptionGuid          = ''                # N/A for GCP
    SubscriptionName          = $project          # Overloaded with GCP Project for downstream processing
    TenantGuid                = $workspaceTenantId
    FitScore                  = 1
    Tags                      = $tags
    DetailsURL                = $detailsUrl
  }
}

# ===================== Emit recommendations =====================
$fileDate = if ($dateStamp) { $dateStamp } else { (Get-Date -Format 'yyyyMMdd-HHmmss') }
$outFile  = "gcp-underutilized-vms-offhours-recommendations-$fileDate.json"
$outPath  = Join-Path $env:TEMP $outFile
$recommendations | ConvertTo-Json -Depth 6 | Set-Content -Path $outPath

try {
  if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }
  $saCtxReco = New-AzStorageContext -StorageAccountName $storageAccountSink -UseConnectedAccount -Environment $cloudEnvironment
  Set-AzStorageBlobContent -Context $saCtxReco -Container $recoContainer -File $outPath -Blob $outFile -Force | Out-Null
}
finally {
  if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }
}

Write-Output ("[{0}] Exported {1} underutilized-vm recommendations to '{2}/{3}'." -f (Get-Date -Format o), $recommendations.Count, $recoContainer, $outFile)
Remove-Item $tempCsv -Force
Remove-Item $outPath -Force
