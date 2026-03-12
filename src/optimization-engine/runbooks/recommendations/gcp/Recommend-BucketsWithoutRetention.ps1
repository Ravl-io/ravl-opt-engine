param(
  [Parameter(Mandatory = $false)]
  [string] $env = 'IGMF-Common-Services',

  [Parameter(Mandatory = $false)]
  # Use YYYY-MM-DD to lock to a specific export (gcp-bucketswithoutretention-YYYY-MM-DD.csv)
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
# Your bash script’s azcopy example uses the 'gcp' container
$gcpExportsContainer        = Get-AutomationVariable -Name 'AzureOptimization_GcpExportsContainer' -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($gcpExportsContainer)) { $gcpExportsContainer = 'gcpexports' }

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
# Expected columns in CSV: "project","name","location","storage_class","lifecycle_rules_count","has_retention","public_access_prevention","ubla_enabled","creation_time","update_time","bucketSizeBytes","bucketSizeGB",
#                          "bytesOlderThan180","gbOlderThan180","currentPriceUSDPerGBMo","targetClass","targetPriceUSDPerGBMo","costSavingsCAD"
$pattern = if ($dateStamp) { "gcp-bucketswithoutretention-$dateStamp.csv" } else { "gcp-bucketswithoutretention-*.csv" }

# Blob list/reads must use the subscription holding the storage account
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

$blobs = Get-AzStorageBlob -Context $saCtx -Container $gcpExportsContainer | Where-Object { $_.Name -like $pattern }
if (-not $blobs) {
    Write-Warning "No GCP Buckets Without Retention CSV found in container '$gcpExportsContainer' matching pattern '$pattern'. No recommendation will be created."
    return
}

$targetBlob = if ($dateStamp) { $blobs | Select-Object -First 1 } else { $blobs | Sort-Object LastModified -Descending | Select-Object -First 1 }
$tempCsv = Join-Path $env:TEMP $targetBlob.Name
Get-AzStorageBlobContent -Context $saCtx -Container $gcpExportsContainer -Blob $targetBlob.Name -Destination $tempCsv -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# ===================== Import & filter (same style) =====================
$raw  = Import-Csv -LiteralPath $tempCsv

# Validate minimal fields
$rows = $raw | Where-Object {
  (-not [string]::IsNullOrWhiteSpace($_.project)) -and
  (-not [string]::IsNullOrWhiteSpace($_.name))
}

Write-Output ("Rows after validation: {0}/{1}" -f $rows.Count, $raw.Count)
if ($rows.Count -eq 0) {
  Remove-Item $tempCsv -Force
  Write-Warning 'No qualifying rows to recommend after filtering.'
  return
}

# ===================== Helpers (same style) =====================
function New-GcpBucketDeepLink {
  param([string]$Project,[string]$Bucket)
  # https://console.cloud.google.com/storage/browser/{bucket}?project={project}
  "https://console.cloud.google.com/storage/browser/$Bucket?project=$Project"
}

function Get-FitScoreForBucket {
  param([string]$storageClass)
  # Simple heuristic: standard classes get higher priority
  switch -Regex ($storageClass) {
    'STANDARD|MULTI_REGIONAL|REGIONAL' { return 4 }
    default { return 3 }
  }
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
  $project      = [string]$r.project
  $bucketName   = [string]$r.name
  $location     = [string]$r.location
  $storageClass = [string]$r.storage_class
  $bucketSizeGB = $r.bucketSizeGB -as [double]
  $gbOlderThan180 = $r.gbOlderThan180 -as [double]
  $currentPriceUSDPerGBMo = $r.currentPriceUSDPerGBMo -as [double]
  $targetClass = [string]$r.targetClass
  $targetPriceUSDPerGBMo = $r.targetPriceUSDPerGBMo -as [double]
  $costSavingsCAD = $r.costSavingsCAD -as [double]
  $currentMonthlyCostCAD = $r.currentMonthlyCostCAD -as [double]
  $bucketLabels = [string]$r.bucketLabels
  $cloud     = if ($r.Cloud) { [string]$r.Cloud } else { 'GCP' }

  # parse Labels string into a dictionary (GCP Labels parsed as Tags)
  $tags = @{}
  if ($bucketLabels) {
    $s = [string]$bucketLabels
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

  $detailsUrl = New-GcpBucketDeepLink -Project $project -Bucket $bucketName
  $resourceId = "/projects/$project/buckets/$bucketName"

  $additional = @{
    SourceCloud      = 'GCP'
    Project          = $project
    Location         = $location
    StorageClass     = $storageClass
    LifecycleRules   = 'None'
    RetentionPolicy  = 'None'
    PublicAccessPrevention = $publicAccessPrevention
    UblaEnabled      = $ublaEnabled
    CreationTime     = $creationTime
    UpdateTime       = $updateTime
    BucketSizeBytes  = $bucketSizeBytes
    BucketSizeGB     = $bucketSizeGB
    BytesOlderThan180 = $bytesOlderThan180
    GbOlderThan180   = $gbOlderThan180
    CurrentPriceUSDPerGBMo = $currentPriceUSDPerGBMo
    TargetClass      = $targetClass
    TargetPriceUSDPerGBMo = $targetPriceUSDPerGBMo
    CurrentMonthlyCost = $currentMonthlyCost
    CurrentMonthlyCostCAD = $currentMonthlyCostCAD
    CurrentMonthlyCostCurrency = $currentMonthlyCostCurrency
    CurrentMonthlyCostLookbackDays = $currentMonthlyCostLookbackDays
    GrossCost        = $grossCost
    CreditsAmount    = $creditsAmount
    BucketLabels     = $bucketLabels
    CostsAmount      = $currentMonthlyCostCAD
    savingsAmount    = $costSavingsCAD
    Signal           = 'Bucket has neither lifecycle rules nor a retention policy'
    EstimationMethod = 'Presence/absence of GCS lifecycle & retention configs from export and savings moving 180 day old datat to lower tier'
  }

  [pscustomobject]@{
    Timestamp                 = $timestamp
    Cloud                     = 'GCP'
    Category                  = 'Cost'
    ImpactedArea              = 'storage.buckets'
    Impact                    = 'Medium'
    RecommendationType        = 'Saving'
    RecommendationSubType     = 'BucketWithoutRetention'
    RecommendationSubTypeId   = '2f9d1a04-8a41-4a5a-9eb3-c9c9f29b2a01'
    RecommendationDescription = 'GCS bucket has no lifecycle rule and no retention policy; risk of unintended data growth or premature deletions.'
    RecommendationAction      = 'Define lifecycle rules (e.g., transition/archive/delete) and/or apply a bucket retention policy per data governance standards.'
    InstanceId                = $resourceId
    InstanceName              = $bucketName
    AdditionalInfo            = $additional
    ResourceGroup             = ''                # N/A for GCP
    SubscriptionGuid          = ''                # N/A for GCP
    SubscriptionName          = $project          # Overloaded with GCP Project for downstream processing
    TenantGuid                = $workspaceTenantId
    FitScore                  = Get-FitScoreForBucket -storageClass $storageClass
    Tags                      = $tags
    DetailsURL                = $detailsUrl
  }
}

# ===================== Export (same style) =====================
$fileDate = $nowUtc.ToString('yyyy-MM-dd')
$outFile  = "gcp-buckets-without-retention-recommendations-$fileDate.json"

$recommendations | ConvertTo-Json | Out-File $outFile -Encoding utf8

# Storage ops again happen in the storage sub if different
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

Set-AzStorageBlobContent -File $outFile -Container $recoContainer -Blob $outFile -Context $saCtx -Properties @{ 'ContentType' = 'application/json' } -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# Cleanup
Remove-Item $outFile -Force
Remove-Item $tempCsv -Force

$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Output "[$now] Exported $($recommendations.Count) GCS bucket recommendations to '$recoContainer/$outFile'."
