param(
  [Parameter(Mandatory = $false)]
  [string] $env = 'IGMF-Common-Services',

  [Parameter(Mandatory = $false)]
  # Use YYYY-MM-DD to lock to a specific export (gcp-idle-services-YYYY-MM-DD.csv)
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
# Expected columns: LocationScope,platform,serviceName,project,Region,requestCount30d,utilizationStatus,
# CostsAmount,Cloud,currency,actualCost,actualCostCAD,potentialSavings,potentialSavingsCAD,
# costLookbackDays,grossCost,creditsAmount,serviceLabels
$pattern = if ($dateStamp) { "gcp-idle-services-$dateStamp.csv" } else { "gcp-idle-services-*.csv" }

if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

$blobs = Get-AzStorageBlob -Context $saCtx -Container $gcpExportsContainer | Where-Object { $_.Name -like $pattern }
if (-not $blobs) {
  Write-Warning "No GCP Idle Services CSV found in container '$gcpExportsContainer' matching pattern '$pattern'. No recommendation will be created."
  return
}

$targetBlob = if ($dateStamp) { $blobs | Select-Object -First 1 } else { $blobs | Sort-Object LastModified -Descending | Select-Object -First 1 }
$tempCsv = Join-Path $env:TEMP $targetBlob.Name
Get-AzStorageBlobContent -Context $saCtx -Container $gcpExportsContainer -Blob $targetBlob.Name -Destination $tempCsv -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# ===================== Import & filter =====================
$raw  = Import-Csv -LiteralPath $tempCsv
$rows = $raw | Where-Object {
  (-not [string]::IsNullOrWhiteSpace($_.serviceName)) -and
  (-not [string]::IsNullOrWhiteSpace($_.project)) -and
  (-not [string]::IsNullOrWhiteSpace($_.platform)) -and
  ($null -ne ($_.CostsAmount -as [double]))
}
Write-Output ("Rows after validation: {0}/{1}" -f $rows.Count, $raw.Count)
if ($rows.Count -eq 0) {
  Remove-Item $tempCsv -Force
  Write-Warning 'No qualifying rows to recommend after filtering.'
  return
}

# ===================== Helpers =====================
function New-GcpServiceDeepLink {
  param([string]$Project, [string]$ServiceName, [string]$Region, [string]$Platform)

  if ($Platform -eq 'Cloud Run') {
    "https://console.cloud.google.com/run/detail/$Region/$ServiceName/metrics?project=$Project"
  }
  elseif ($Platform -eq 'App Engine') {
    "https://console.cloud.google.com/appengine/services/detail/$ServiceName?project=$Project"
  }
  else {
    "https://console.cloud.google.com/home/dashboard?project=$Project"
  }
}

function Get-FitScoreForService {
  param([string]$Platform, [double]$SavingsCAD)
  if ($Platform -eq 'App Engine') {
    if ($SavingsCAD -gt 30) { return 5 } else { return 4 }
  }
  elseif ($Platform -eq 'Cloud Run') {
    if ($SavingsCAD -gt 15) { return 4 } else { return 3 }
  }
  else {
    return 3
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
  $serviceName     = [string]$r.serviceName
  $platform        = [string]$r.platform
  $region          = [string]$r.Region
  $requestCount30d = $r.requestCount30d -as [double]
  $costCAD         = $r.CostsAmount -as [double]
  if ($null -eq $costCAD) { $costCAD = 0 }
  $savingsCAD      = $r.potentialSavingsCAD -as [double]
  if ($null -eq $savingsCAD -or $savingsCAD -eq 0) { $savingsCAD = $costCAD }
  $savingsUSD      = $r.potentialSavings -as [double]
  if ($null -eq $savingsUSD -or $savingsUSD -eq 0) { $savingsUSD = $r.actualCost -as [double] }
  if ($null -eq $savingsUSD) { $savingsUSD = 0 }
  $labels          = [string]$r.serviceLabels
  $cloud           = if ($r.Cloud) { [string]$r.Cloud } else { 'GCP' }
  $utilization     = [string]$r.utilizationStatus
  if (-not $utilization) { $utilization = 'idle' }

  $tags = ConvertTo-TagsFromLabelString -LabelString $labels

  $detailsUrl = New-GcpServiceDeepLink -Project $project -ServiceName $serviceName -Region $region -Platform $platform
  $resourceId = if ($platform -eq 'Cloud Run') {
    "/projects/$project/locations/$region/services/$serviceName"
  } else {
    "/projects/$project/services/$serviceName"
  }

  $impactedArea = if ($platform -eq 'Cloud Run') { 'compute.cloudrun' } else { 'compute.appengine' }
  $impact = if ($savingsCAD -gt 30) { 'High' } elseif ($savingsCAD -gt 15) { 'Medium' } else { 'Low' }

  $additional = @{}
  $additional['SourceCloud']          = $cloud
  $additional['Project']              = $project
  $additional['Platform']             = $platform
  $additional['Region']               = $region
  $additional['RequestCount30d']      = $requestCount30d
  $additional['UtilizationStatus']    = $utilization
  $additional['Currency']             = $defaultCurrencyCode
  $additional['CostsAmount']          = [Math]::Round($costCAD, 2)
  $additional['savingsAmount']        = [Math]::Round($savingsCAD, 2)
  $additional['ActualCost']           = $r.actualCost -as [double]
  $additional['ActualCostCAD']        = $r.actualCostCAD -as [double]
  $additional['PotentialSavings']     = $r.potentialSavings -as [double]
  $additional['PotentialSavingsCAD']  = $r.potentialSavingsCAD -as [double]
  $additional['CostLookbackDays']     = $r.costLookbackDays -as [double]
  $additional['GrossCost']            = $r.grossCost -as [double]
  $additional['CreditsAmount']        = $r.creditsAmount -as [double]
  $additional['ServiceLabels']        = $labels
  $additional['EstimationMethod']     = "Net BigQuery billing cost over $($r.costLookbackDays) days (converted to CAD)"
  $additional['Signal']               = 'Service has recorded 0 requests in the lookback window'

  [pscustomobject]@{
    Timestamp                 = $timestamp
    Cloud                     = 'GCP'
    Category                  = 'Cost'
    ImpactedArea              = $impactedArea
    Impact                    = $impact
    RecommendationType        = 'Saving'
    RecommendationSubType     = 'IdleService'
    RecommendationSubTypeId   = '5e652b7a-249c-4453-9778-015c533c27a4'
    RecommendationDescription = "$platform service '$serviceName' has been idle for $($r.costLookbackDays)-day lookback with zero traffic, representing potential cost savings."
    RecommendationAction      = "Review service necessity and decommission or consolidate if no longer required. Confirm with service owners before deletion."
    InstanceId                = $resourceId
    InstanceName              = $serviceName
    AdditionalInfo            = $additional
    ResourceGroup             = ''
    SubscriptionGuid          = ''
    SubscriptionName          = $project
    TenantGuid                = $workspaceTenantId
    FitScore                  = Get-FitScoreForService -Platform $platform -SavingsCAD $savingsCAD
    Tags                      = $tags
    DetailsURL                = $detailsUrl
  }
}

# ===================== Export =====================
$fileDate = $nowUtc.ToString('yyyy-MM-dd')
$outFile  = "gcp-idle-services-recommendations-$fileDate.json"

$recommendations | ConvertTo-Json | Out-File $outFile -Encoding utf8

if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

Set-AzStorageBlobContent -File $outFile -Container $recoContainer -Blob $outFile -Context $saCtx -Properties @{ 'ContentType' = 'application/json' } -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# Cleanup
Remove-Item $outFile -Force
Remove-Item $tempCsv -Force

$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Output "[$now] Exported $($recommendations.Count) idle service recommendations to '$recoContainer/$outFile'."
