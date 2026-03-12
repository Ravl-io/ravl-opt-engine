param(
  [Parameter(Mandatory = $false)]
  [string] $env = 'IGMF-Common-Services',

  [Parameter(Mandatory = $false)]
  # Use YYYY-MM-DD to lock to a specific export (gcp-unattached-ips-YYYY-MM-DD.csv)
  [string] $dateStamp
)

$ErrorActionPreference = 'Stop'

# ===================== Config (aligned with CAD disk runbook) =====================
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

# Container holding the CSV exported by the CAD Bash runbook
$gcpExportsContainer        = Get-AutomationVariable -Name 'AzureOptimization_GcpExportsContainer' -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($gcpExportsContainer)) { $gcpExportsContainer = 'gcpexports' }

# Default currency code to stamp on costs (export CSV doesn’t include it)
$defaultCurrencyCode        = Get-AutomationVariable -Name 'AzureOptimization_DefaultCurrencyCode' -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($defaultCurrencyCode)) { $defaultCurrencyCode = 'CAD' }

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

# ===================== Locate latest CSV =====================
# Expected columns in CSV: "LocationScope","ipName","ipAddress","networkTier","addressType","purpose","status",
# "project","Region","CostsAmount","Cloud","currency","actualCost","actualCostCAD","potentialSavings",
# "potentialSavingsCAD","costLookbackDays","grossCost","creditsAmount","ipLabels"
$pattern = if ($dateStamp) { "gcp-unattached-ips-$dateStamp.csv" } else { "gcp-unattached-ips-*.csv" }

# Blob list/reads must use the subscription holding the storage account
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

$blobs = Get-AzStorageBlob -Context $saCtx -Container $gcpExportsContainer | Where-Object { $_.Name -like $pattern }
if (-not $blobs) {
  Write-Warning "No GCP Unattached IPs CSV found in container '$gcpExportsContainer' matching pattern '$pattern'. No recommendation will be created."
  return
}

$targetBlob = if ($dateStamp) { $blobs | Select-Object -First 1 } else { $blobs | Sort-Object LastModified -Descending | Select-Object -First 1 }
$tempCsv = Join-Path $env:TEMP $targetBlob.Name
Get-AzStorageBlobContent -Context $saCtx -Container $gcpExportsContainer -Blob $targetBlob.Name -Destination $tempCsv -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# ===================== Import & filter =====================
$raw  = Import-Csv -LiteralPath $tempCsv
$rows = $raw | Where-Object {
  (-not [string]::IsNullOrWhiteSpace($_.LocationScope)) -and
  (-not [string]::IsNullOrWhiteSpace($_.ipName)) -and
  (-not [string]::IsNullOrWhiteSpace($_.ipAddress)) -and
  (-not [string]::IsNullOrWhiteSpace($_.project)) -and
  (-not [string]::IsNullOrWhiteSpace($_.Region)) -and
  ($null -ne ($_.CostsAmount -as [double]))
}
Write-Output ("Rows after validation: {0}/{1}" -f $rows.Count, $raw.Count)
if ($rows.Count -eq 0) {
  Remove-Item $tempCsv -Force
  Write-Warning 'No qualifying rows to recommend after filtering.'
  return
}

# ===================== Helpers =====================
function New-GcpIPDeepLink {
  param([string]$Project, [string]$LocationScope, [string]$AddressName)

  if ($LocationScope -eq 'global' -or [string]::IsNullOrWhiteSpace($LocationScope)) {
    "https://console.cloud.google.com/networking/addresses/details/global/$AddressName?project=$Project"
  } else {
    "https://console.cloud.google.com/networking/addresses/details/$LocationScope/$AddressName?project=$Project"
  }
}

function Get-FitScoreForIP {
  param([string]$NetworkTier, [double]$SavingsCAD)
  if ($NetworkTier -eq 'PREMIUM') {
    if ($SavingsCAD -gt 20) { return 5 } else { return 4 }
  }
  else {
    if ($SavingsCAD -gt 10) { return 4 } else { return 3 }
  }
}

function ConvertTo-TagsFromLabelString {
  param([string]$LabelString)
  $tags = @{}
  if (-not $LabelString) { return $tags }

  $s = $LabelString.Trim()
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

function New-ResourceDeepLink {
  param([string]$InstanceId, [string]$CloudEnv, [string]$TenantId)
  return $null
}

# ===================== Build recommendations =====================
$nowUtc    = (Get-Date).ToUniversalTime()
$timestamp = $nowUtc.ToString('yyyy-MM-ddTHH:mm:00.000Z')

$recommendations = foreach ($r in $rows) {
  $project         = [string]$r.project
  $locationScope   = [string]$r.LocationScope
  $region          = [string]$r.Region
  if ([string]::IsNullOrWhiteSpace($locationScope)) { $locationScope = if ($region) { $region } else { 'global' } }
  $ipName          = [string]$r.ipName
  $ipAddress       = [string]$r.ipAddress
  $networkTier     = [string]$r.networkTier
  $status          = [string]$r.status
  $addressType     = [string]$r.addressType
  $purpose         = [string]$r.purpose
  $cloud           = if ($r.Cloud) { [string]$r.Cloud } else { 'GCP' }
  $costCAD         = $r.CostsAmount -as [double]
  if ($null -eq $costCAD) { $costCAD = 0 }
  $savingsCAD      = $r.potentialSavingsCAD -as [double]
  if ($null -eq $savingsCAD -or $savingsCAD -eq 0) { $savingsCAD = $costCAD }
  $savingsUSD      = $r.potentialSavings -as [double]
  if ($null -eq $savingsUSD -or $savingsUSD -eq 0) { $savingsUSD = $r.actualCost -as [double] }
  if ($null -eq $savingsUSD) { $savingsUSD = 0 }
  $labels          = [string]$r.ipLabels

  $tags = ConvertTo-TagsFromLabelString -LabelString $labels

  $detailsUrl = New-GcpIPDeepLink -Project $project -LocationScope $locationScope -AddressName $ipName
  $resourceId = if ($locationScope -eq 'global') {
    "/projects/$project/global/addresses/$ipName"
  } else {
    "/projects/$project/regions/$locationScope/addresses/$ipName"
  }

  $impact = if ($savingsCAD -gt 25) { 'High' } elseif ($savingsCAD -gt 12) { 'Medium' } else { 'Low' }

  $additional = @{}
  $additional['SourceCloud']        = $cloud
  $additional['project']            = $project
  $additional['Region']             = $region
  $additional['NetworkTier']        = $networkTier
  $additional['AddressType']        = $addressType
  $additional['Status']             = $status
  $additional['Purpose']            = $purpose
  $additional['IPAddress']          = $ipAddress
  $additional['Currency']           = $defaultCurrencyCode
  $additional['CostsAmount']        = [Math]::Round($costCAD, 2)
  $additional['savingsAmount']      = [Math]::Round($savingsCAD, 2)
  $additional['ActualCost']         = $r.actualCost -as [double]
  $additional['ActualCostCAD']      = $r.actualCostCAD -as [double]
  $additional['PotentialSavings']   = $r.potentialSavings -as [double]
  $additional['PotentialSavingsCAD']= $r.potentialSavingsCAD -as [double]
  $additional['CostLookbackDays']   = $r.costLookbackDays -as [double]
  $additional['GrossCost']          = $r.grossCost -as [double]
  $additional['CreditsAmount']      = $r.creditsAmount -as [double]
  $additional['IPLabels']           = $labels
  $additional['EstimationMethod']   = "Net BigQuery billing cost over $($r.costLookbackDays) days (converted to CAD)"
  $additional['Signal']             = 'Static IP is RESERVED with no attached users'

  [pscustomobject]@{
    Timestamp                 = $timestamp
    Cloud                     = 'GCP'
    Category                  = 'Cost'
    ImpactedArea              = 'compute.addresses'
    Impact                    = $impact
    RecommendationType        = 'Saving'
    RecommendationSubType     = 'UnattachedIP'
    RecommendationSubTypeId   = '5b51afff-9d97-4ded-8d5c-9fb1448c461f'
    RecommendationDescription = "External IP address '$ipName' ($ipAddress) is reserved but not attached to any resources, incurring unnecessary charges."
    RecommendationAction      = "Release the unused IP address if no longer needed, or attach it to a resource if it serves a purpose. Confirm with network administrators before deletion."
    InstanceId                = $resourceId
    InstanceName              = $ipName
    AdditionalInfo            = $additional
    ResourceGroup             = ''                # N/A for GCP
    SubscriptionGuid          = ''                # N/A for GCP
    SubscriptionName          = $project          # Overloaded with GCP Project for downstream processing
    TenantGuid                = $workspaceTenantId
    FitScore                  = Get-FitScoreForIP -NetworkTier $networkTier -SavingsCAD $savingsCAD
    Tags                      = $tags
    DetailsURL                = $detailsUrl
  }
}

# ===================== Export =====================
$fileDate = $nowUtc.ToString('yyyy-MM-dd')
$outFile  = "gcp-unattached-ips-recommendations-$fileDate.json"

$recommendations | ConvertTo-Json | Out-File $outFile -Encoding utf8

# Storage ops again happen in the storage sub if different
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

Set-AzStorageBlobContent -File $outFile -Container $recoContainer -Blob $outFile -Context $saCtx -Properties @{ 'ContentType' = 'application/json' } -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# Cleanup
Remove-Item $outFile -Force
Remove-Item $tempCsv -Force

$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Output "[$now] Exported $($recommendations.Count) unattached-IP recommendations to '$recoContainer/$outFile'."
