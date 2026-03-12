param(
  [Parameter(Mandatory = $false)]
  [string] $env = 'IGMF-Common-Services',

  [Parameter(Mandatory = $false)]
  # Use YYYY-MM-DD to lock to a specific export (releasable_eips_YYYYMMDD-HHMMSS.csv)
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
  $csvPattern = 'releasable_eips_*'
  if (-not [string]::IsNullOrWhiteSpace($dateStamp)) {
    # Convert YYYY-MM-DD to YYYYMMDD format expected by AWS scripts
    $cleanDate = $dateStamp.Replace('-', '')
    $csvPattern = "releasable_eips_$cleanDate*"
  }

  $blobs = Get-AzStorageBlob -Container $awsExportsContainer -Context $saCtx | 
           Where-Object { $_.Name -like "$csvPattern.csv" } | 
           Sort-Object LastModified -Descending

  if (-not $blobs) { 
    Write-Warning "No Unattached AWS EIPs CSV found in container '$awsExportsContainer' matching pattern '$csvPattern.csv'. No recommendations can be created."
    return
  }

  $latestBlob = $blobs[0]
  $tempCsv = [System.IO.Path]::GetTempFileName() + '.csv'
  Get-AzStorageBlobContent -Blob $latestBlob.Name -Container $awsExportsContainer -Destination $tempCsv -Context $saCtx | Out-Null

  Write-Output "Processing AWS releasable EIPs export: $($latestBlob.Name)"

} finally {
  if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }
}

# ===================== Parse CSV =====================
$rows = Import-Csv -Path $tempCsv

# ===================== Helper Functions =====================
function Get-AWSUnattachedEIPConsoleUrl {
  param([string]$AllocationId, [string]$Region, [string]$Account)
  
  "https://$Region.console.aws.amazon.com/ec2/home?region=$Region#Addresses:allocationId=$AllocationId"
}

function Get-FitScoreForUnattachedEIP {
  param([string]$PublicIp, [double]$SavingsCAD, [string]$Domain)
  # Higher fit score for VPC EIPs (more expensive) and higher savings
  if ($Domain -eq 'vpc') {
    if ($SavingsCAD -gt 50) { return 5 }
    elseif ($SavingsCAD -gt 30) { return 4 } 
    else { return 3 }
  }
  else {
    if ($SavingsCAD -gt 30) { return 4 }
    elseif ($SavingsCAD -gt 15) { return 3 } 
    else { return 2 }
  }
}

function New-ResourceDeepLink {
  param([string]$AllocationId, [string]$CloudEnv, [string]$TenantId)
  return $null
}

# ===================== Build recommendations =====================
$nowUtc    = (Get-Date).ToUniversalTime()
$timestamp = $nowUtc.ToString('yyyy-MM-ddTHH:mm:00.000Z')

$recommendations = foreach ($r in $rows) {
  $account                 = [string]$r.account
  $region                  = [string]$r.region
  $allocationId            = [string]$r.allocation_id
  $publicIp                = [string]$r.public_ip
  $domain                  = [string]$r.domain
  $networkBorderGroup      = [string]$r.network_border_group
  $publicIpv4Pool          = [string]$r.public_ipv4_pool
  $customerOwnedIp         = [string]$r.customer_owned_ip
  $customerOwnedIpv4Pool   = [string]$r.customer_owned_ipv4_pool
  $carrierIp               = [string]$r.carrier_ip
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
  $resourceId = "arn:aws:ec2:${region}:${account}:elastic-ip/$allocationId"
  
  # Build impact assessment - unattached EIPs are waste, so savings = full cost
  $monthlySavingsUSD = $monthlyCostUSD
  $monthlySavingsCAD = $monthlyCostCAD
  $impact = if ($monthlySavingsCAD -gt 50) { 'High' } elseif ($monthlySavingsCAD -gt 25) { 'Medium' } else { 'Low' }
  
  # Build additional info object
  $additional = @{
    Account                = $account
    Region                 = $region
    AllocationId           = $allocationId
    PublicIp               = $publicIp
    Domain                 = $domain
    NetworkBorderGroup     = $networkBorderGroup
    PublicIpv4Pool         = $publicIpv4Pool
    CustomerOwnedIp        = $customerOwnedIp
    CustomerOwnedIpv4Pool  = $customerOwnedIpv4Pool
    CarrierIp              = $carrierIp
    MonthlyCostUSD         = $monthlyCostUSD
    MonthlyCostCAD         = $monthlyCostCAD
    CostsAmount            = $monthlySavingsCAD
    savingsAmount          = $monthlySavingsCAD
    SavingsUSD             = $monthlySavingsUSD
    Signal                 = "Elastic IP not associated with any resource"
    EstimationMethod       = "Direct cost calculation for unattached EIPs using FOCUS billing data"
  }
  
  # Build details URL
  $detailsUrl = Get-AWSUnattachedEIPConsoleUrl -AllocationId $allocationId -Region $region -Account $account

  [pscustomobject]@{
    Timestamp                 = $timestamp
    Cloud                     = 'AWS'
    Category                  = 'Cost'
    ImpactedArea              = 'ec2.addresses'
    Impact                    = $impact
    RecommendationType        = 'Saving'
    RecommendationSubType     = 'UnattachedElasticIP'
    RecommendationSubTypeId   = 'c3f8d1a5-6e9b-4f7c-8a2d-5b4e7c9a1f63'
    RecommendationDescription = "Elastic IP is unattached and generating unnecessary costs. EIP should be released to avoid charges."
    RecommendationAction      = "Consider releasing unattached Elastic IP to avoid charges. Verify no future association plans before release."
    InstanceId                = $resourceId
    InstanceName              = $publicIp
    AdditionalInfo            = $additional
    ResourceGroup             = ''                # N/A for AWS
    SubscriptionGuid          = ''                # N/A for AWS  
    SubscriptionName          = $account          # Overloaded with AWS Account for downstream processing
    TenantGuid                = $workspaceTenantId
    FitScore                  = Get-FitScoreForUnattachedEIP -PublicIp $publicIp -SavingsCAD $monthlySavingsCAD -Domain $domain
    Tags                      = $tags
    DetailsURL                = $detailsUrl
  }
}

# ===================== Export (same style) =====================
$fileDate = $nowUtc.ToString('yyyy-MM-dd')
$outFile  = "aws-unattached-eips-recommendations-$fileDate.json"

$recommendations | ConvertTo-Json | Out-File $outFile -Encoding utf8

# Storage ops again happen in the storage sub if different
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

Set-AzStorageBlobContent -File $outFile -Container $recoContainer -Blob $outFile -Context $saCtx -Properties @{ 'ContentType' = 'application/json' } -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# Cleanup
Remove-Item $outFile -Force
Remove-Item $tempCsv -Force

$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Output "[$now] Exported $($recommendations.Count) AWS unattached EIP recommendations to '$recoContainer/$outFile'."