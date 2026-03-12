param(
  [Parameter(Mandatory = $false)]
  [string] $env = 'IGMF-Common-Services',

  [Parameter(Mandatory = $false)]
  # Use YYYY-MM-DD to lock to a specific export (underutilized_rds_instances_YYYYMMDD-HHMMSS.csv)
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
  $csvPattern = 'underutilized_rds_instances_*'
  if (-not [string]::IsNullOrWhiteSpace($dateStamp)) {
    # Convert YYYY-MM-DD to YYYYMMDD format expected by AWS scripts
    $cleanDate = $dateStamp.Replace('-', '')
    $csvPattern = "underutilized_rds_instances_$cleanDate*"
  }

  $blobs = Get-AzStorageBlob -Container $awsExportsContainer -Context $saCtx | 
           Where-Object { $_.Name -like "$csvPattern.csv" } | 
           Sort-Object LastModified -Descending

  if (-not $blobs) { 
    Write-Warning "No Underutilized AWS RDS Instances CSV found in container '$awsExportsContainer' matching pattern '$csvPattern.csv'. No recommendations can be created."
    return
  }

  $latestBlob = $blobs[0]
  $tempCsv = [System.IO.Path]::GetTempFileName() + '.csv'
  Get-AzStorageBlobContent -Blob $latestBlob.Name -Container $awsExportsContainer -Destination $tempCsv -Context $saCtx | Out-Null

  Write-Output "Processing AWS RDS instances export: $($latestBlob.Name)"

} finally {
  if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }
}

# ===================== Parse CSV =====================
$rows = Import-Csv -Path $tempCsv

# ===================== Helper Functions =====================
function Get-AWSRDSConsoleUrl {
  param([string]$DBInstanceIdentifier, [string]$Region, [string]$Account)
  
  "https://$Region.console.aws.amazon.com/rds/home?region=$Region#database:id=$DBInstanceIdentifier"
}

function Get-FitScoreForRDSInstance {
  param([string]$InstanceClass, [double]$SavingsCAD, [string]$Engine)
  # Higher fit score for higher-performance instances, production engines, and higher savings
  if ($InstanceClass -match '^db\.(r5|r6i|x1)') {
    if ($SavingsCAD -gt 200) { return 5 } elseif ($SavingsCAD -gt 100) { return 4 } else { return 3 }
  }
  elseif ($InstanceClass -match '^db\.(m5|m6i)') {
    if ($SavingsCAD -gt 100) { return 4 } elseif ($SavingsCAD -gt 50) { return 3 } else { return 2 }
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
  $account                   = [string]$r.account
  $region                    = [string]$r.region
  $dbInstanceIdentifier      = [string]$r.db_instance_identifier
  $engine                    = [string]$r.engine
  $engineVersion             = [string]$r.engine_version
  $instanceClass             = [string]$r.instance_class
  $recommendedTargetClass    = [string]$r.recommended_target_class
  $instanceState             = [string]$r.instance_state
  $multiAZ                   = [string]$r.multi_az
  $cpu95thPercent            = $r.cpu_95th_percent -as [double]
  $connectionsAvg            = $r.connections_avg -as [double]
  $currentPriceUSDMonth      = $r.current_price_usd_month -as [double]
  $targetPriceUSDMonth       = $r.target_price_usd_month -as [double]
  $monthlySavingsUSD         = $r.monthly_savings_usd -as [double]
  $monthlySavingsCAD         = $r.monthly_savings_cad -as [double]
  $creationTime              = [string]$r.creation_time
  $tags_raw                  = [string]$r.tags

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
  $resourceId = "arn:aws:rds:${region}:${account}:db:$dbInstanceIdentifier"
  
  # Build impact assessment
  $impact = if ($monthlySavingsCAD -gt 200) { 'High' } elseif ($monthlySavingsCAD -gt 100) { 'Medium' } else { 'Low' }
  
  # Build additional info object
  $additional = @{
    Account                   = $account
    Region                    = $region
    DBInstanceIdentifier      = $dbInstanceIdentifier
    Engine                    = $engine
    EngineVersion             = $engineVersion
    InstanceClass             = $instanceClass
    RecommendedTargetClass    = $recommendedTargetClass
    InstanceState             = $instanceState
    MultiAZ                   = $multiAZ
    CPU95thPercent            = $cpu95thPercent
    ConnectionsAvg            = $connectionsAvg
    CurrentPriceUSDMonth      = $currentPriceUSDMonth
    TargetPriceUSDMonth       = $targetPriceUSDMonth
    CostsAmount               = $monthlySavingsCAD
    savingsAmount             = $monthlySavingsCAD
    SavingsUSD                = $monthlySavingsUSD
    CreationTime              = $creationTime
    Tags                      = $tags
    Signal                    = "Low CPU utilization and connection count"
    EstimationMethod          = "30-day CPU and connection analysis with FOCUS billing data for instance class recommendations"
  }
  
  # Build details URL
  $detailsUrl = Get-AWSRDSConsoleUrl -DBInstanceIdentifier $dbInstanceIdentifier -Region $region -Account $account

  [pscustomobject]@{
    Timestamp                 = $timestamp
    Cloud                     = 'AWS'
    Category                  = 'Cost'
    ImpactedArea              = 'rds.instances'
    Impact                    = $impact
    RecommendationType        = 'Saving'
    RecommendationSubType     = 'UnderutilizedRDSInstance'
    RecommendationSubTypeId   = 'a4b9d7c3-5e8f-4a1b-9c6d-7f2e5a8b4c91'
    RecommendationDescription = "RDS instance is underutilized and can be right-sized to a smaller instance class for cost savings."
    RecommendationAction      = "Consider right-sizing RDS instance to a smaller instance class. Verify workload requirements and performance needs before making changes."
    InstanceId                = $resourceId
    InstanceName              = $dbInstanceIdentifier
    AdditionalInfo            = $additional
    ResourceGroup             = ''                # N/A for AWS
    SubscriptionGuid          = ''                # N/A for AWS  
    SubscriptionName          = $account          # Overloaded with AWS Account for downstream processing
    TenantGuid                = $workspaceTenantId
    FitScore                  = Get-FitScoreForRDSInstance -InstanceClass $instanceClass -SavingsCAD $monthlySavingsCAD -Engine $engine
    Tags                      = $tags
    DetailsURL                = $detailsUrl
  }
}

# ===================== Export (same style) =====================
$fileDate = $nowUtc.ToString('yyyy-MM-dd')
$outFile  = "aws-underutilized-rds-instances-recommendations-$fileDate.json"

$recommendations | ConvertTo-Json | Out-File $outFile -Encoding utf8

# Storage ops again happen in the storage sub if different
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

Set-AzStorageBlobContent -File $outFile -Container $recoContainer -Blob $outFile -Context $saCtx -Properties @{ 'ContentType' = 'application/json' } -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# Cleanup
Remove-Item $outFile -Force
Remove-Item $tempCsv -Force

$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Output "[$now] Exported $($recommendations.Count) AWS underutilized RDS instance recommendations to '$recoContainer/$outFile'."