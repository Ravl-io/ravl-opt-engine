param(
  [Parameter(Mandatory = $false)]
  [ValidateSet('vm','vmss')]
  [string] $vmssOrVm = 'vm',
 
  [Parameter(Mandatory = $false)]
  [string] $env = 'IGMF-Common-Services',

  [Parameter(Mandatory = $false)]
  [string] $dateStamp
)

$ErrorActionPreference = 'Stop'

# Config
$cloudEnvironment = Get-AutomationVariable -Name 'AzureOptimization_CloudEnvironment'
if (-not $cloudEnvironment) { $cloudEnvironment = 'AzureCloud' }

$workspaceId             = Get-AutomationVariable -Name 'AzureOptimization_LogAnalyticsWorkspaceId'
$workspaceName           = Get-AutomationVariable -Name 'AzureOptimization_LogAnalyticsWorkspaceName'
$workspaceRG             = Get-AutomationVariable -Name 'AzureOptimization_LogAnalyticsWorkspaceRG'
$workspaceSubscriptionId = Get-AutomationVariable -Name 'AzureOptimization_LogAnalyticsWorkspaceSubId'
$workspaceTenantId       = Get-AutomationVariable -Name 'AzureOptimization_LogAnalyticsWorkspaceTenantId'
$lognamePrefix           = Get-AutomationVariable -Name 'AzureOptimization_LogAnalyticsLogPrefix' -ErrorAction SilentlyContinue
if (-not $lognamePrefix) { $lognamePrefix = 'AzureOptimization' }
$deploymentDate          = (Get-AutomationVariable -Name 'AzureOptimization_DeploymentDate').Replace('"','')

$storageAccountSink      = Get-AutomationVariable -Name 'AzureOptimization_StorageSink'
$storageAccountSinkRG    = Get-AutomationVariable -Name 'AzureOptimization_StorageSinkRG'
$recoContainer           = Get-AutomationVariable -Name 'AzureOptimization_RecommendationsContainer' -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($recoContainer)) { $recoContainer = 'recommendationsexports' }

$metricsContainer        = 'vmsunderutilizedoffhoursexports'

$offHoursStart           = Get-AutomationVariable -Name 'AzureOptimization_OffHoursStart'
$offHoursEnd             = Get-AutomationVariable -Name 'AzureOptimization_OffHoursEnd'
$offHoursDays            = Get-AutomationVariable -Name 'AzureOptimization_OffHoursDays'

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

$sa    = Get-AzStorageAccount -ResourceGroupName $storageAccountSinkRG -Name $storageAccountSink
$saCtx = New-AzStorageContext -StorageAccountName $storageAccountSink -UseConnectedAccount -Environment $cloudEnvironment

# Locate latest CSV
$pattern = if ($dateStamp) { "$dateStamp-underutilized-$vmssOrVm-$env.csv" } else { "*-underutilized-$vmssOrVm-$env.csv" }
$blobs = Get-AzStorageBlob -Context $saCtx -Container $metricsContainer | Where-Object { $_.Name -like $pattern }
if (-not $blobs) { throw "No CSV found in '$metricsContainer' with pattern '$pattern'." }

$targetBlob = if ($dateStamp) { $blobs | Select-Object -First 1 } else { $blobs | Sort-Object LastModified -Descending | Select-Object -First 1 }
$tempCsv = Join-Path $env:TEMP $targetBlob.Name
Get-AzStorageBlobContent -Context $saCtx -Container $metricsContainer -Blob $targetBlob.Name -Destination $tempCsv -Force | Out-Null

# Import OffHoursUtilizationAverage
$raw  = Import-Csv -LiteralPath $tempCsv
$rows = $raw | Where-Object {
  $v = $_.OffHoursUtilizationAverage
  (-not [string]::IsNullOrWhiteSpace($v)) -and ($null -ne ($v -as [double]))
}
Write-Output ("Rows after filtering blank OffHoursUtilizationAverage: {0}/{1}" -f $rows.Count, $raw.Count)
if ($rows.Count -eq 0) {
  Remove-Item $tempCsv -Force
  Write-Warning 'No qualifying rows to recommend after filtering.'
  return
}

# Helpers
function Normalize-ShutPct {
  param([object]$x)
  if ($null -eq $x) { return $null }
  $d = $x -as [double]
  if ($null -eq $d) { return $null }
  if ($d -le 1) { return [Math]::Round($d * 100, 2) }
  else { return [Math]::Round($d, 2) }
}

function New-ResourceDeepLink {
  param([string]$InstanceId, [string]$CloudEnv, [string]$TenantId)
  $tld = 'com'
  if ($CloudEnv -eq 'AzureChinaCloud') { $tld = 'cn' }
  elseif ($CloudEnv -eq 'AzureUSGovernment') { $tld = 'us' }
  return ("https://portal.azure.{0}/#@{1}/resource/{2}/overview" -f $tld, $TenantId, $InstanceId)
}

# Build recommendations
$nowUtc    = (Get-Date).ToUniversalTime()
$timestamp = $nowUtc.ToString('yyyy-MM-ddTHH:mm:00.000Z')

$recommendations = foreach ($r in $rows) {
  $instanceId   = $r.ResourceId
  $instanceName = $r.VM
  $rg           = $r.ResourceGroupName
  $subId        = $r.SubscriptionGuid
  $subName      = $r.SubscriptionName
  $cloud        = if ($r.Cloud) { $r.Cloud } else { 'AzureCloud' }

  $avgUtil = $r.OffHoursUtilizationAverage -as [double]
  $shutPct = Normalize-ShutPct $r.ShutOffPercentage
  $monthly = $r.MonthlyCosts -as [double]
  $savings = $r.SavingsAmount -as [double]
  if ($null -eq $savings -and $monthly -ne $null -and $shutPct -ne $null) {
    $savings = [Math]::Round($monthly * ($shutPct / 100.0), 2)
  }

  # parse Tags string into a dictionary
  $tags = @{}
  if ($r.Tags) {
    $s = [string]$r.Tags
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

  $detailsUrl = New-ResourceDeepLink -InstanceId $instanceId -CloudEnv $cloudEnvironment -TenantId $workspaceTenantId

  $additional = @{
    OffHoursWindow             = ("{0} {1}-{2}, Sat/Sun 24H Offline" -f $offHoursDays, $offHoursStart, $offHoursEnd).Trim()
    OffHoursUtilizationAverage = $avgUtil
    ShutOffPercentage          = $shutPct
    MonthlyCosts               = $monthly
    CostsAmount                = $monthly
    savingsAmount              = $savings
    EstimationMethod           = 'Off-hours share × last-30d VM costs (from CSV export)'
  }

  [pscustomobject]@{
    Timestamp                 = $timestamp
    Cloud                     = $cloud
    Category                  = 'Cost'
    ImpactedArea              = 'Microsoft.Compute/virtualMachines'
    Impact                    = 'Medium'
    RecommendationType        = 'Saving'
    RecommendationSubType     = 'UnderutilizedOffHours'
    RecommendationSubTypeId   = '6f8b8fd3-9fe3-4d8f-9d8a-6d1d9040c1b1'
    RecommendationDescription = 'VM shows persistent low utilization during the defined off-hours window.'
    RecommendationAction      = 'Automate deallocation during off-hours (start/stop schedule).'
    InstanceId                = $instanceId
    InstanceName              = $instanceName
    AdditionalInfo            = $additional
    ResourceGroup             = $rg
    SubscriptionGuid          = $subId
    SubscriptionName          = $subName
    TenantGuid                = $workspaceTenantId
    FitScore                  = 5
    Tags                      = $tags
    DetailsURL                = $detailsUrl
  }
}

$recommendations = $recommendations | Where-Object { $_.AdditionalInfo.OffHoursUtilizationAverage -is [double] }

# Export
$fileDate = $nowUtc.ToString('yyyy-MM-dd')
$outFile  = "underutilizedoffhoursvms-$fileDate.json"

$recommendations | ConvertTo-Json | Out-File $outFile -Encoding utf8
Set-AzStorageBlobContent -File $outFile -Container $recoContainer -Blob $outFile -Context $saCtx -Properties @{ 'ContentType' = 'application/json' } -Force | Out-Null

Remove-Item $outFile -Force
Remove-Item $tempCsv -Force

$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Output "[$now] Exported $($recommendations.Count) recommendations to '$recoContainer/$outFile'."