param(
  [Parameter(Mandatory = $false)]
  [string] $env = 'IGMF-Common-Services',

  [Parameter(Mandatory = $false)]
  # Use YYYY-MM-DD to lock to a specific export (unattached_ebs_volumes_YYYYMMDD-HHMMSS.csv)
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
  $csvPattern = 'unattached_ebs_volumes_*'
  if (-not [string]::IsNullOrWhiteSpace($dateStamp)) {
    # Convert YYYY-MM-DD to YYYYMMDD format expected by AWS scripts
    $cleanDate = $dateStamp.Replace('-', '')
    $csvPattern = "unattached_ebs_volumes_$cleanDate*"
  }

  $blobs = Get-AzStorageBlob -Container $awsExportsContainer -Context $saCtx | 
           Where-Object { $_.Name -like "$csvPattern.csv" } | 
           Sort-Object LastModified -Descending

  if (-not $blobs) { 
    Write-Warning "No Unattached AWS EBS Volumes CSV found in container '$awsExportsContainer' matching pattern '$csvPattern.csv'. No recommendations can be created."
    return
  }

  $latestBlob = $blobs[0]
  $tempCsv = [System.IO.Path]::GetTempFileName() + '.csv'
  Get-AzStorageBlobContent -Blob $latestBlob.Name -Container $awsExportsContainer -Destination $tempCsv -Context $saCtx | Out-Null

  Write-Output "Processing AWS unattached EBS volumes export: $($latestBlob.Name)"

} finally {
  if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }
}

# ===================== Parse CSV =====================
$rows = Import-Csv -Path $tempCsv

# ===================== Helper Functions =====================
function Get-AWSUnattachedVolumeConsoleUrl {
  param([string]$VolumeId, [string]$Region, [string]$Account)
  
  "https://$Region.console.aws.amazon.com/ec2/home?region=$Region#Volumes:volumeId=$VolumeId"
}

function Get-FitScoreForUnattachedVolume {
  param([string]$VolumeType, [double]$SavingsCAD, [int]$SizeGB)
  # Higher fit score for larger volumes, higher savings, and more expensive volume types
  if ($VolumeType -in @('io1', 'io2', 'gp3')) {
    if ($SavingsCAD -gt 200 -and $SizeGB -gt 100) { return 5 }
    elseif ($SavingsCAD -gt 100) { return 4 } 
    else { return 3 }
  }
  elseif ($VolumeType -eq 'gp2') {
    if ($SavingsCAD -gt 100 -and $SizeGB -gt 100) { return 4 }
    elseif ($SavingsCAD -gt 50) { return 3 } 
    else { return 2 }
  }
  else {
    if ($SavingsCAD -gt 50) { return 3 } else { return 2 }
  }
}

function New-ResourceDeepLink {
  param([string]$VolumeId, [string]$CloudEnv, [string]$TenantId)
  return $null
}

# ===================== Build recommendations =====================
$nowUtc    = (Get-Date).ToUniversalTime()
$timestamp = $nowUtc.ToString('yyyy-MM-ddTHH:mm:00.000Z')

$recommendations = foreach ($r in $rows) {
  $account                 = [string]$r.account
  $region                  = [string]$r.region
  $volumeId                = [string]$r.volume_id
  $volumeType              = [string]$r.volume_type
  $sizeGB                  = $r.size_gb -as [int]
  $state                   = [string]$r.state
  $availabilityZone        = [string]$r.availability_zone
  $encrypted               = [string]$r.encrypted
  $kmsKeyId                = [string]$r.kms_key_id
  $iops                    = $r.iops -as [int]
  $throughput              = $r.throughput -as [int]
  $snapshotId              = [string]$r.snapshot_id
  $createTime              = [string]$r.create_time
  $monthlyCostUSD          = $r.monthly_cost_usd -as [double]
  $monthlyCostCAD          = $r.monthly_cost_cad -as [double]
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
  $resourceId = "arn:aws:ec2:${region}:${account}:volume/$volumeId"
  
  # Build impact assessment - unattached volumes are waste, so savings = full cost
  $monthlySavingsUSD = $monthlyCostUSD
  $monthlySavingsCAD = $monthlyCostCAD
  $impact = if ($monthlySavingsCAD -gt 200) { 'High' } elseif ($monthlySavingsCAD -gt 100) { 'Medium' } else { 'Low' }
  
  # Build additional info object
  $additional = @{
    Account                = $account
    Region                 = $region
    VolumeId               = $volumeId
    VolumeType             = $volumeType
    SizeGB                 = $sizeGB
    State                  = $state
    AvailabilityZone       = $availabilityZone
    Encrypted              = $encrypted
    KmsKeyId               = $kmsKeyId
    Iops                   = $iops
    Throughput             = $throughput
    SnapshotId             = $snapshotId
    CreateTime             = $createTime
    MonthlyCostUSD         = $monthlyCostUSD
    MonthlyCostCAD         = $monthlyCostCAD
    CostsAmount            = $monthlySavingsCAD
    savingsAmount          = $monthlySavingsCAD
    SavingsUSD             = $monthlySavingsUSD
    Signal                 = "Volume not attached to any EC2 instance"
    EstimationMethod       = "Direct cost calculation for unattached volumes using FOCUS billing data"
  }
  
  # Build details URL
  $detailsUrl = Get-AWSUnattachedVolumeConsoleUrl -VolumeId $volumeId -Region $region -Account $account

  [pscustomobject]@{
    Timestamp                 = $timestamp
    Cloud                     = 'AWS'
    Category                  = 'Cost'
    ImpactedArea              = 'ec2.volumes'
    Impact                    = $impact
    RecommendationType        = 'Saving'
    RecommendationSubType     = 'UnattachedEBSVolume'
    RecommendationSubTypeId   = 'd9a6c4e2-7b8f-4c3a-9e5d-2f7a1c8b6e94'
    RecommendationDescription = "EBS volume is unattached and generating unnecessary costs. Volume can be safely deleted or archived."
    RecommendationAction      = "Consider deleting unattached EBS volume after verifying it's not needed. If data is important, create snapshot before deletion."
    InstanceId                = $resourceId
    InstanceName              = $volumeId
    AdditionalInfo            = $additional
    ResourceGroup             = ''                # N/A for AWS
    SubscriptionGuid          = ''                # N/A for AWS  
    SubscriptionName          = $account          # Overloaded with AWS Account for downstream processing
    TenantGuid                = $workspaceTenantId
    FitScore                  = Get-FitScoreForUnattachedVolume -VolumeType $volumeType -SavingsCAD $monthlySavingsCAD -SizeGB $sizeGB
    Tags                      = $tags
    DetailsURL                = $detailsUrl
  }
}

# ===================== Export (same style) =====================
$fileDate = $nowUtc.ToString('yyyy-MM-dd')
$outFile  = "aws-unattached-ebs-volumes-recommendations-$fileDate.json"

$recommendations | ConvertTo-Json | Out-File $outFile -Encoding utf8

# Storage ops again happen in the storage sub if different
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

Set-AzStorageBlobContent -File $outFile -Container $recoContainer -Blob $outFile -Context $saCtx -Properties @{ 'ContentType' = 'application/json' } -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# Cleanup
Remove-Item $outFile -Force
Remove-Item $tempCsv -Force

$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Output "[$now] Exported $($recommendations.Count) AWS unattached EBS volume recommendations to '$recoContainer/$outFile'."