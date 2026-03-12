param(
  [Parameter(Mandatory = $false)]
  [string] $env = 'IGMF-Common-Services',

  [Parameter(Mandatory = $false)]
  # Use YYYY-MM-DD to lock to a specific export (gcp-unused-load-balancers-YYYY-MM-DD.csv)
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
# export-unusedlb-test.sh and export-unused-gcp-load-balancers.sh copy to gcptest; fall back to gcpexports
$gcpExportsContainer        = Get-AutomationVariable -Name 'AzureOptimization_GcpExportsContainer' -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($gcpExportsContainer)) { $gcpExportsContainer = 'gcpexports' }
# $gcpExportsContainer='gcptest'
# $recoContainer ='recommendationstest'
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
# Expected columns in CSV: "Project","Load Balancer Name","Load Balancer Type","Scope","Region","Reason Unused","Backend Count","Request Count 30 Days","Creation Timestamp","Description","Cost Savings USD","Cost Savings CAD","Monthly Cost USD","Monthly Cost CAD","Gross Cost","Credits Amount","Currency","Actual Cost Lookback Days","Load Balancer Labels"
$pattern = if ($dateStamp) { "gcp-unused-load-balancers-$dateStamp.csv" } else { "gcp-unused-load-balancers-*.csv" }

# Blob list/reads must use the subscription holding the storage account
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

$blobs = $null
$blobs = Get-AzStorageBlob -Context $saCtx -Container $gcpExportsContainer | Where-Object { $_.Name -like $pattern }
if (-not $blobs) {
  Write-Warning "No GCP Unused Load Balancers CSV found in container '$gcpExportsContainer' matching pattern '$pattern'. No recommendation will be created."
  return
}

$targetBlob = if ($dateStamp) { $blobs | Select-Object -First 1 } else { $blobs | Sort-Object LastModified -Descending | Select-Object -First 1 }
$tempCsv = Join-Path $env:TEMP $targetBlob.Name
Get-AzStorageBlobContent -Context $saCtx -Container $gcpExportsContainer -Blob $targetBlob.Name -Destination $tempCsv -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# ===================== Import & filter (same style) =====================
$raw  = Import-Csv -LiteralPath $tempCsv

# Validate minimal fields - CSV already contains only unused or low-usage load balancers
$rows = $raw | Where-Object {
  (-not [string]::IsNullOrWhiteSpace($_.Project)) -and
  (-not [string]::IsNullOrWhiteSpace($_.'Load Balancer Name')) -and
  ([double]$_.'Monthly Cost CAD' -gt 0)
}

Write-Output ("Rows after validation: {0}/{1}" -f $rows.Count, $raw.Count)
if ($rows.Count -eq 0) {
  Remove-Item $tempCsv -Force
  Write-Warning 'No qualifying rows to recommend after filtering.'
  return
}

$colMonthlyCostUsd      = if ($rows[0].PSObject.Properties['Monthly Cost USD'])      { 'Monthly Cost USD' }      else { $null }
$colMonthlyCostCad      = if ($rows[0].PSObject.Properties['Monthly Cost CAD'])      { 'Monthly Cost CAD' }      else { $null }
$colGrossCost           = if ($rows[0].PSObject.Properties['Gross Cost'])            { 'Gross Cost' }            else { $null }
$colCreditsAmount       = if ($rows[0].PSObject.Properties['Credits Amount'])        { 'Credits Amount' }        else { $null }
$colCurrency            = if ($rows[0].PSObject.Properties['Currency'])              { 'Currency' }              else { $null }
$colActualCostLookback  = if ($rows[0].PSObject.Properties['Actual Cost Lookback Days']) { 'Actual Cost Lookback Days' } else { $null }

# ===================== Helpers =====================
function New-GcpLoadBalancerDeepLink {
  param([string]$Project, [string]$LoadBalancerName, [string]$LoadBalancerType, [string]$Region)
  
  $baseUrl = "https://console.cloud.google.com/net-services/loadbalancing/list/loadBalancers"
  return "$baseUrl`?project=$Project"
}

function Get-FitScoreForLoadBalancer {
  param([string]$ReasonUnused, [int]$BackendCount, [double]$SavingsCAD)
  
  $score = 3  # Base score
  
  if ($ReasonUnused -match "No backend") {
    $score = 5
  }
  elseif ($ReasonUnused -match "Low usage") {
    $score = 4
  }
  elseif ($ReasonUnused -match "No URL map") {
    $score = 5
  }
  
  if ($SavingsCAD -gt 50) {
    $score = [Math]::Min($score + 1, 5)
  }
  
  return $score
}

function New-ResourceDeepLink {
  param([string]$InstanceId, [string]$CloudEnv, [string]$TenantId)
  return $null
}

# ===================== Build recommendations =====================
$nowUtc    = (Get-Date).ToUniversalTime()
$timestamp = $nowUtc.ToString('yyyy-MM-ddTHH:mm:00.000Z')

$recommendations = foreach ($r in $rows) {
  $project           = [string]$r.Project
  $loadBalancerName  = [string]$r.'Load Balancer Name'
  $loadBalancerType  = [string]$r.'Load Balancer Type'
  $scope             = [string]$r.Scope
  $region            = [string]$r.Region
  $reasonUnused      = [string]$r.'Reason Unused'
  $backendCount      = $r.'Backend Count' -as [int]
  $requestCount30d   = if ($r.PSObject.Properties['Request Count 30 Days']) { $r.'Request Count 30 Days' -as [int] } else { $null }
  $savingsUSD        = $r.'Cost Savings USD' -as [double]
  $savingsCAD        = $r.'Cost Savings CAD' -as [double]
  $monthlyCostUSD    = if ($colMonthlyCostUsd) { $r.$colMonthlyCostUsd -as [double] } else { $savingsUSD }
  $monthlyCostCAD    = if ($colMonthlyCostCad) { $r.$colMonthlyCostCad -as [double] } else { $savingsCAD }
  $grossCost         = if ($colGrossCost) { $r.$colGrossCost -as [double] } else { $null }
  $creditsAmount     = if ($colCreditsAmount) { $r.$colCreditsAmount -as [double] } else { $null }
  $currency          = if ($colCurrency) { [string]$r.$colCurrency } else { 'CAD' }
  $actualCostWindow  = if ($colActualCostLookback) { $r.$colActualCostLookback -as [int] } else { $null }
  $labels            = [string]$r.'Load Balancer Labels'
  $creationTimestamp = [string]$r.'Creation Timestamp'
  $description       = [string]$r.Description

  $tags = @{}
  if ($labels) {
    $s = [string]$labels
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

  $detailsUrl = New-GcpLoadBalancerDeepLink -Project $project -LoadBalancerName $loadBalancerName -LoadBalancerType $loadBalancerType -Region $region
  $resourceId = "/projects/$project/global/loadBalancers/$loadBalancerName"
  if ($region -and $region -ne "Global") {
    $resourceId = "/projects/$project/regions/$region/loadBalancers/$loadBalancerName"
  }

  $impactedArea = 'compute.loadbalancing'
  $impact = if ($savingsCAD -gt 50) { 'High' } elseif ($savingsCAD -gt 20) { 'Medium' } else { 'Low' }

  $recommendationAction = if ($reasonUnused -match "Low usage") {
    "Review load balancer usage patterns and consider consolidating or removing if traffic remains consistently low."
  } else {
    "Remove unused load balancer as it has no backend services configured and is generating unnecessary costs."
  }

  $effectiveCostsAmount   = if ($monthlyCostCAD -ne $null) { [Math]::Round($monthlyCostCAD, 2) } else { [Math]::Round($savingsCAD, 2) }
  $effectiveSavingsCad    = if ($savingsCAD -ne $null) { [Math]::Round($savingsCAD, 2) } else { $effectiveCostsAmount }
  $effectiveSavingsUsd    = if ($savingsUSD -ne $null) { [Math]::Round($savingsUSD, 2) } else { $null }

  $additional = @{
    SourceCloud            = 'GCP'
    Project                = $project
    LoadBalancerType       = $loadBalancerType
    Scope                  = $scope
    Region                 = $region
    ReasonUnused           = $reasonUnused
    BackendCount           = $backendCount
    RequestCount30d        = $requestCount30d
    CreationTimestamp      = $creationTimestamp
    Description            = $description
    MonthlyCostUSD         = $monthlyCostUSD
    MonthlyCostCAD         = $monthlyCostCAD
    GrossCost              = $grossCost
    CreditsAmount          = $creditsAmount
    Currency               = $currency
    ActualCostLookbackDays = $actualCostWindow
    CostSavingsCAD         = $savingsCAD
    CostSavingsUSD         = $savingsUSD
    CostsAmount            = $effectiveCostsAmount
    savingsAmount          = $effectiveSavingsCad
    SavingsUSD             = $effectiveSavingsUsd
    Labels                 = $labels
    Signal                 = $reasonUnused
    EstimationMethod       = "30-day billing data with unused/low-usage signals"
  }

  [pscustomobject]@{
    Timestamp                 = $timestamp
    Cloud                     = 'GCP'
    Category                  = 'Cost'
    ImpactedArea              = $impactedArea
    Impact                    = $impact
    RecommendationType        = 'Saving'
    RecommendationSubType     = 'UnusedLoadBalancer'
    RecommendationSubTypeId   = '46d2ee27-d943-4839-9795-b4f5aa67ca75'
    RecommendationDescription = "$loadBalancerType '$loadBalancerName' in project '$project' is unused: $reasonUnused"
    RecommendationAction      = $recommendationAction
    InstanceId                = $resourceId
    InstanceName              = $loadBalancerName
    AdditionalInfo            = $additional
    ResourceGroup             = ''                # N/A for GCP
    SubscriptionGuid          = ''                # N/A for GCP
    SubscriptionName          = $project          # Overloaded with GCP Project for downstream processing
    TenantGuid                = $workspaceTenantId
    FitScore                  = Get-FitScoreForLoadBalancer -ReasonUnused $reasonUnused -BackendCount $backendCount -SavingsCAD $effectiveSavingsCad
    Tags                      = $tags
    DetailsURL                = $detailsUrl
  }
}

# ===================== Export (same style) =====================
$fileDate = $nowUtc.ToString('yyyy-MM-dd')
$outFile  = "gcp-unused-load-balancers-recommendations-$fileDate.json"

$recommendations | ConvertTo-Json | Out-File $outFile -Encoding utf8

# Storage ops again happen in the storage sub if different
if ($needAltSub) { Set-AzContext -SubscriptionId $storageAccountSinkSubId | Out-Null }

Set-AzStorageBlobContent -File $outFile -Container $recoContainer -Blob $outFile -Context $saCtx -Properties @{ 'ContentType' = 'application/json' } -Force | Out-Null

if ($needAltSub) { Set-AzContext -SubscriptionObject $originalContext | Out-Null }

# Cleanup
Remove-Item $outFile -Force
Remove-Item $tempCsv -Force

$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-Output "[$now] Exported $($recommendations.Count) GCP unused load balancer (CAD) recommendations to '$recoContainer/$outFile'."
