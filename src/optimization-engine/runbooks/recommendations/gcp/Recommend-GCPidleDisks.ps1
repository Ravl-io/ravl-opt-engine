param(
  [Parameter(Mandatory = $false)]
  [string] $env = 'IGMF-Common-Services',

  [Parameter(Mandatory = $false)]
  # Use YYYY-MM-DD to lock to a specific export (gcp-idle-disks-YYYY-MM-DD.csv)
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
# Expected columns in CSV: "project","vmName","vmZone","diskName","diskZone","sizeGb","diskType","diskStatus","deviceName","boot","autoDelete","mode","unitPriceUSDPerGBMo","costSavingsUSD","costSavingsCAD"
$pattern = if ($dateStamp) { "gcp-idle-disks-$dateStamp.csv" } else { "gcp-idle-disks-*.csv" }

# Blob list/reads must use the subscription holding the storage account
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

$blobs = Get-AzStorageBlob -Context $saCtx -Container $gcpExportsContainer | Where-Object { $_.Name -like $pattern }
if (-not $blobs) { 
    Write-Warning "No GCP Idle DisksCSV found in container '$gcpExportsContainer' matching pattern '$pattern'. No recommendation will be created."
    return
}

$targetBlob = if ($dateStamp) { $blobs | Select-Object -First 1 } else { $blobs | Sort-Object LastModified -Descending | Select-Object -First 1 }
$tempCsv = Join-Path $env:TEMP $targetBlob.Name
Get-AzStorageBlobContent -Context $saCtx -Container $gcpExportsContainer -Blob $targetBlob.Name -Destination $tempCsv -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# ===================== Import & filter (same style) =====================
$raw  = Import-Csv -LiteralPath $tempCsv
$rows = $raw | Where-Object {
  (-not [string]::IsNullOrWhiteSpace($_.project)) -and
  (-not [string]::IsNullOrWhiteSpace($_.vmName)) -and
  (-not [string]::IsNullOrWhiteSpace($_.vmZone)) -and
  (-not [string]::IsNullOrWhiteSpace($_.diskName)) -and
  (-not [string]::IsNullOrWhiteSpace($_.diskZone)) -and
  ($null -ne ($_.sizeGb -as [double])) -and
  (-not [string]::IsNullOrWhiteSpace($_.diskType)) -and
  (-not [string]::IsNullOrWhiteSpace($_.diskStatus)) -and
  (-not [string]::IsNullOrWhiteSpace($_.deviceName)) -and
  (-not [string]::IsNullOrWhiteSpace($_.boot)) -and
  (-not [string]::IsNullOrWhiteSpace($_.autoDelete)) -and
  (-not [string]::IsNullOrWhiteSpace($_.mode)) -and
  ($null -ne ($_.unitPriceUSDPerGBMo -as [double])) -and
  ($null -ne ($_.costSavingsUSD -as [double])) -and
  ($null -ne ($_.costSavingsCAD -as [double]))
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
  $vmName    = [string]$r.vmName
  $vmZone      = [string]$r.vmZone
  $diskName  = [string]$r.diskName
  $diskZone  = [string]$r.diskZone
  $sizeGB  = $r.sizeGb -as [double]
  $diskType   = [string]$r.diskType
  $diskStatus   = [string]$r.diskStatus
  $deviceName   = [string]$r.deviceName
  $boot   = [string]$r.boot
  $autoDelete   = [string]$r.autoDelete
  $mode   = [string]$r.mode
  $unitPriceUSDPerGBMo  = $r.unitPriceUSDPerGBMo -as [double]
  $costSavingsUSD  = $r.costSavingsUSD -as [double]
  $costSavingsCAD  = $r.costSavingsCAD -as [double]
  $potentialSavingsCAD = $r.potentialSavingsCAD -as [double]
  $diskLabels = [string]$r.diskLabels
  $cloud     = if ($r.Cloud) { [string]$r.Cloud } else { 'GCP' }
  $costsAmount = $r.actualCostCAD -as [double]

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

  #$cost      = $r.CostsAmount -as [double]
  #if ($cost -lt 0) { $cost = -1 * $cost }  # normalize if negative

  $detailsUrl = New-GcpDiskDeepLink -Project $project -Zone $zone -Disk $diskName
  $resourceId = "/projects/$project/zones/$zone/disks/$diskName"

  $additional = @{
    SourceCloud      = $cloud
    project          = $Project
    vmName           = $vmName
    diskName         = $diskName
    diskZone         = $diskZone
    sizeGB           = $sizeGB
    diskType         = $diskType
    diskStatus       = $diskStatus
    deviceName       = $deviceName
    boot             = $boot
    autoDelete       = $autoDelete
    mode             = $mode
    unitPriceUSDPerGBMo = $unitPriceUSDPerGBMo
    costSavingsUSD   = $costSavingsUSD
    GrossCost        = $grossCost
    CreditsAmount    = $creditsAmount
    DiskLabels       = $labels
    Currency         = $defaultCurrencyCode
    CostsAmount      = [Math]::Round($costsAmount, 2)
    savingsAmount    = [Math]::Round($potentialSavingsCAD, 2)
    EstimationMethod = 'Size x regional price (from export)'
    Signal           = 'Idle (attached to TERMINATED machine)'
  }

  [pscustomobject]@{
    Timestamp                 = $timestamp
    Cloud                     = 'GCP'
    Category                  = 'Cost'
    ImpactedArea              = 'compute.disks'
    Impact                    = 'Medium'
    RecommendationType        = 'Saving'
    RecommendationSubType     = 'IdleDisk'
    RecommendationSubTypeId   = '91615d2a-f28b-40a5-927c-ff7e14c184d6'
    RecommendationDescription = 'Terminated VM with persistent disk is idle and incurring monthly cost'
    RecommendationAction      = 'Review, snapshot if needed, then delete the disk.'
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
$outFile  = "gcp-idle-disks-recommendations-$fileDate.json"

$recommendations | ConvertTo-Json | Out-File $outFile -Encoding utf8

# Storage ops again happen in the storage sub if different
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

Set-AzStorageBlobContent -File $outFile -Container $recoContainer -Blob $outFile -Context $saCtx -Properties @{ 'ContentType' = 'application/json' } -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# Cleanup
Remove-Item $outFile -Force
Remove-Item $tempCsv -Force

$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Output "[$now] Exported $($recommendations.Count) idle-disk recommendations to '$recoContainer/$outFile'."
