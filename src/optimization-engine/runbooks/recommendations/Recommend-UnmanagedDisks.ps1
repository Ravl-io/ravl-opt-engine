param(
  [Parameter(Mandatory = $false)]
  [string] $env = 'IGMF-Common-Services',
 
  [Parameter(Mandatory = $false)]
  # Use YYYY-MM-DD to lock to a specific export (gcp-unmanaged-disks-YYYY-MM-DD.csv)
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

# Container holding the orphaned disks CSV exported by your Bash runbook
$gcpExportsContainer        = Get-AutomationVariable -Name 'AzureOptimization_GcpExportsContainer' -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($gcpExportsContainer)) { $gcpExportsContainer = 'gcpexports' }

# Default currency code to stamp on costs (export CSV doesn’t include it)
$defaultCurrencyCode        = Get-AutomationVariable -Name 'AzureOptimization_DefaultCurrencyCode' -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($defaultCurrencyCode)) { $defaultCurrencyCode = 'CAD' }

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
  if ($needAltSub) {
    Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null
  }

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
  if ($needAltSub) {
    Set-AzContext -SubscriptionObject $originalContext | Out-Null
  }
}

# ===================== Locate latest CSV (same blob pattern style) =====================
# Expected columns in CSV: "LocationScope","diskName","diskSize","diskSku","project","Region","CostsAmount","Cloud"
$pattern = if ($dateStamp) { "gcp-unmanaged-disks-$dateStamp.csv" } else { "gcp-unmanaged-disks-*.csv" }

# Blob list/reads must use the subscription holding the storage account
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

$blobs = Get-AzStorageBlob -Context $saCtx -Container $gcpExportsContainer | Where-Object { $_.Name -like $pattern }
if (-not $blobs) { 
  if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }
  throw "No CSV found in '$gcpExportsContainer' with pattern '$pattern'." 
}

$targetBlob = if ($dateStamp) { $blobs | Select-Object -First 1 } else { $blobs | Sort-Object LastModified -Descending | Select-Object -First 1 }
$tempCsv = Join-Path $env:TEMP $targetBlob.Name
Get-AzStorageBlobContent -Context $saCtx -Container $gcpExportsContainer -Blob $targetBlob.Name -Destination $tempCsv -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# ===================== Import & filter (same style) =====================
$raw  = Import-Csv -LiteralPath $tempCsv
$rows = $raw | Where-Object {
  (-not [string]::IsNullOrWhiteSpace($_.LocationScope)) -and
  (-not [string]::IsNullOrWhiteSpace($_.diskName)) -and
  ($null -ne ($_.diskSize -as [double])) -and
  (-not [string]::IsNullOrWhiteSpace($_.diskSku)) -and
  (-not [string]::IsNullOrWhiteSpace($_.project)) -and
  (-not [string]::IsNullOrWhiteSpace($_.Region)) -and
  (-not [string]::IsNullOrWhiteSpace($_.Cloud)) -and
  ($null -ne ($_.CostsAmount -as [double]))
}
Write-Output ("Rows after validation: {0}/{1}" -f $rows.Count, $raw.Count)
if ($rows.Count -eq 0) {
  Remove-Item $tempCsv -Force
  Write-Warning 'No qualifying rows to recommend after filtering.'
  return
}

# ===================== Helpers (same style) =====================
function New-GcpDiskDeepLink {
  param([string]$Project,[string]$Zone,[string]$Disk)
  # https://console.cloud.google.com/compute/disksDetail/zones/{zone}/disks/{disk}?project={project}
  "https://console.cloud.google.com/compute/disksDetail/zones/$Zone/disks/$Disk?project=$Project"
}

function New-ResourceDeepLink {
  param([string]$InstanceId, [string]$CloudEnv, [string]$TenantId)
  # Kept for parity with your Azure runbook (not used for GCP resource)
  return $null
}

# ===================== Build recommendations (only logic that differs) =====================
$nowUtc    = (Get-Date).ToUniversalTime()
$timestamp = $nowUtc.ToString('yyyy-MM-ddTHH:mm:00.000Z')

$recommendations = foreach ($r in $rows) {
  $project   = [string]$r.project
  $zone      = [string]$r.LocationScope
  $region    = [string]$r.Region
  $diskName  = [string]$r.diskName
  $diskSku   = [string]$r.diskSku
  $diskSize  = $r.diskSize -as [double]
  $diskLabels = [string]$r.diskLabels
  $cloud     = if ($r.Cloud) { [string]$r.Cloud } else { 'GCP' }

  # parse Labels string into a dictionary (GCP Labels parsed as Tags)
  $tags = @{}
  if ($diskLabels) {
    $s = [string]$diskLabels
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

  $cost      = $r.CostsAmount -as [double]
  #if ($cost -lt 0) { $cost = -1 * $cost }  # normalize if negative

  $detailsUrl = New-GcpDiskDeepLink -Project $project -Zone $zone -Disk $diskName
  $resourceId = "/projects/$project/zones/$zone/disks/$diskName"

  $additional = @{
    SourceCloud      = $cloud
    project          = $project
    Zone             = $zone
    Region           = $region
    DiskSku          = $diskSku
    DiskSizeGB       = $diskSize
    Currency         = $defaultCurrencyCode
    CostsAmount      = [Math]::Round($cost, 2)
    savingsAmount    = [Math]::Round($cost, 2)
    ActualCost       = $r.actualCost -as [double]
    ActualCostCAD    = $r.actualCostCAD -as [double]
    PotentialSavings = $r.potentialSavings -as [double]
    PotentialSavingsCAD = $r.potentialSavingsCAD -as [double]
    CostLookbackDays = $r.costLookbackDays -as [double]
    GrossCost        = $r.grossCost -as [double]
    CreditsAmount    = $r.creditsAmount -as [double]
    DiskLabels       = $r.diskLabels
    EstimationMethod = 'Size x regional PD price (from export)'
    Signal           = 'Unattached (no users)'
  }

  [pscustomobject]@{
    Timestamp                 = $timestamp
    Cloud                     = 'GCP'
    Category                  = 'Cost'
    ImpactedArea              = 'compute.disks'
    Impact                    = 'Medium'
    RecommendationType        = 'Saving'
    RecommendationSubType     = 'OrphanedDisk'
    RecommendationSubTypeId   = '8b1f9f1a-3c51-4d3f-8aa8-6a9c8fbd1b01'
    RecommendationDescription = 'Persistent disk is unattached and incurring monthly cost.'
    RecommendationAction      = 'Review, snapshot if needed, then delete the orphaned disk.'
    InstanceId                = $resourceId
    InstanceName              = $diskName
    AdditionalInfo            = $additional
    ResourceGroup             = ''                # N/A for GCP
    SubscriptionGuid          = ''                # N/A for GCP
    SubscriptionName          = $project          # Overloaded with GCP Project for downstream processing
    TenantGuid                = $workspaceTenantId
    FitScore                  = 0
    Tags                      = $tags
    DetailsURL                = $detailsUrl
  }
}

# ===================== Export (same style) =====================
$fileDate = $nowUtc.ToString('yyyy-MM-dd')
$outFile  = "gcp-unmanaged-disks-recommendations-$fileDate.json"

$recommendations | ConvertTo-Json | Out-File $outFile -Encoding utf8

# Storage ops again happen in the storage sub if different
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

Set-AzStorageBlobContent -File $outFile -Container $recoContainer -Blob $outFile -Context $saCtx -Properties @{ 'ContentType' = 'application/json' } -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# Cleanup
Remove-Item $outFile -Force
Remove-Item $tempCsv -Force

$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Output "[$now] Exported $($recommendations.Count) unmanaged-disk recommendations to '$recoContainer/$outFile'."
