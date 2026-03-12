param(
  [Parameter(Mandatory = $false)]
  [string] $env = 'IGMF-Common-Services',

  [Parameter(Mandatory = $false)]
  # Use YYYY-MM-DD to lock to a specific export (underutilized_ec2_instances_YYYYMMDD-HHMMSS.csv)
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
  $csvPattern = 'underutilized_ec2_instances_*'
  if (-not [string]::IsNullOrWhiteSpace($dateStamp)) {
    # Convert YYYY-MM-DD to YYYYMMDD format expected by AWS scripts
    $cleanDate = $dateStamp.Replace('-', '')
    $csvPattern = "underutilized_ec2_instances_$cleanDate*"
  }

  $blobs = Get-AzStorageBlob -Container $awsExportsContainer -Context $saCtx | 
           Where-Object { $_.Name -like "$csvPattern.csv" } | 
           Sort-Object LastModified -Descending

  if (-not $blobs) { 
    Write-Warning "No Underutilized AWS EC2 Instances CSV found in container '$awsExportsContainer' matching pattern '$csvPattern.csv'. No recommendations can be created."
    return
  }

  $latestBlob = $blobs[0]
  $tempCsv = [System.IO.Path]::GetTempFileName() + '.csv'
  Get-AzStorageBlobContent -Blob $latestBlob.Name -Container $awsExportsContainer -Destination $tempCsv -Context $saCtx | Out-Null

  Write-Output "Processing AWS EC2 instances export: $($latestBlob.Name)"

} finally {
  if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }
}

# ===================== Parse CSV =====================
$rows = Import-Csv -Path $tempCsv

# ===================== Helper Functions =====================
function Get-AWSEC2ConsoleUrl {
  param([string]$InstanceId, [string]$Region, [string]$Account)
  
  "https://$Region.console.aws.amazon.com/ec2/home?region=$Region#InstanceDetails:instanceId=$InstanceId"
}

function Get-FitScoreForInstance {
  param([string]$InstanceType, [double]$SavingsCAD, [double]$CpuUtilization)
  # Higher fit score for larger instances, higher savings, and lower CPU utilization
  if ($InstanceType -match '^(m5|m6|c5|c6|r5|r6)\..*large$|^(m5|m6|c5|c6|r5|r6)\..*xlarge$') {
    if ($SavingsCAD -gt 200 -and $CpuUtilization -lt 20) { return 5 }
    elseif ($SavingsCAD -gt 100 -and $CpuUtilization -lt 30) { return 4 } 
    else { return 3 }
  }
  elseif ($InstanceType -match '^(t3|t4)\.') {
    if ($SavingsCAD -gt 50 -and $CpuUtilization -lt 15) { return 4 }
    elseif ($SavingsCAD -gt 25 -and $CpuUtilization -lt 25) { return 3 } 
    else { return 2 }
  }
  else {
    if ($SavingsCAD -gt 100) { return 4 } elseif ($SavingsCAD -gt 50) { return 3 } else { return 2 }
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
  $account                 = [string]$r.account
  $region                  = [string]$r.region
  $instanceId              = [string]$r.instance_id
  $instanceType            = [string]$r.instance_type
  $recommendedTargetType   = [string]$r.recommended_target_type
  $cpu95thPercent          = $r.cpu_95th_percent -as [double]
  $memoryAvgPercent        = $r.memory_avg_percent -as [double]
  $networkInAvgMbps        = $r.network_in_avg_mbps -as [double]
  $networkOutAvgMbps       = $r.network_out_avg_mbps -as [double]
  $monthlyCostUSD          = $r.monthly_cost_usd -as [double]
  $monthlyCostCAD          = $r.monthly_cost_cad -as [double]
  $monthlySavingsUSD       = $r.monthly_savings_usd -as [double]
  $monthlySavingsCAD       = $r.monthly_savings_cad -as [double]
  $state                   = [string]$r.state
  $platform                = [string]$r.platform
  $tenancy                 = [string]$r.tenancy
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
  $resourceId = "arn:aws:ec2:${region}:${account}:instance/$instanceId"
  
  # Build impact assessment
  $impact = if ($monthlySavingsCAD -gt 200) { 'High' } elseif ($monthlySavingsCAD -gt 100) { 'Medium' } else { 'Low' }
  
  # Build additional info object
  $additional = @{
    Account                = $account
    Region                 = $region
    InstanceId             = $instanceId
    InstanceType           = $instanceType
    RecommendedTargetType  = $recommendedTargetType
    Cpu95thPercent         = $cpu95thPercent
    MemoryAvgPercent       = $memoryAvgPercent
    NetworkInAvgMbps       = $networkInAvgMbps
    NetworkOutAvgMbps      = $networkOutAvgMbps
    MonthlyCostUSD         = $monthlyCostUSD
    MonthlyCostCAD         = $monthlyCostCAD
    CostsAmount            = $monthlySavingsCAD
    savingsAmount          = $monthlySavingsCAD
    SavingsUSD             = $monthlySavingsUSD
    State                  = $state
    Platform               = $platform
    Tenancy                = $tenancy
    Signal                 = "Low CPU and memory utilization"
    EstimationMethod       = "30-day CPU, memory, and network analysis with FOCUS billing data for right-sizing recommendations"
  }
  
  # Build details URL
  $detailsUrl = Get-AWSEC2ConsoleUrl -InstanceId $instanceId -Region $region -Account $account

  [pscustomobject]@{
    Timestamp                 = $timestamp
    Cloud                     = 'AWS'
    Category                  = 'Cost'
    ImpactedArea              = 'ec2.instances'
    Impact                    = $impact
    RecommendationType        = 'Saving'
    RecommendationSubType     = 'UnderutilizedEC2Instance'
    RecommendationSubTypeId   = 'e6f2b8d4-3c9a-4d5e-8b7f-1a4c6e9d2b85'
    RecommendationDescription = "EC2 instance is underutilized and can be right-sized to a smaller instance type for cost savings."
    RecommendationAction      = "Consider right-sizing EC2 instance to a smaller instance type. Verify workload requirements and performance needs before making changes."
    InstanceId                = $resourceId
    InstanceName              = $instanceId
    AdditionalInfo            = $additional
    ResourceGroup             = ''                # N/A for AWS
    SubscriptionGuid          = ''                # N/A for AWS  
    SubscriptionName          = $account          # Overloaded with AWS Account for downstream processing
    TenantGuid                = $workspaceTenantId
    FitScore                  = Get-FitScoreForInstance -InstanceType $instanceType -SavingsCAD $monthlySavingsCAD -CpuUtilization $cpu95thPercent
    Tags                      = $tags
    DetailsURL                = $detailsUrl
  }
}

# ===================== Export (same style) =====================
$fileDate = $nowUtc.ToString('yyyy-MM-dd')
$outFile  = "aws-underutilized-ec2-instances-recommendations-$fileDate.json"

$recommendations | ConvertTo-Json | Out-File $outFile -Encoding utf8

# Storage ops again happen in the storage sub if different
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

Set-AzStorageBlobContent -File $outFile -Container $recoContainer -Blob $outFile -Context $saCtx -Properties @{ 'ContentType' = 'application/json' } -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# Cleanup
Remove-Item $outFile -Force
Remove-Item $tempCsv -Force

$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Output "[$now] Exported $($recommendations.Count) AWS underutilized EC2 instance recommendations to '$recoContainer/$outFile'."