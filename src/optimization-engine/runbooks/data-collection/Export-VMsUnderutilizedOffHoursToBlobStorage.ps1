param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("vm", "vmss")]
    [string] $vmssOrVm = "vm",
 
    [Parameter(Mandatory = $false)]
    [string] $env = "IGMF-Common-Services"
)
 
# $ErrorActionPreference = "Stop"

#region --- Initialization & Context Setup ---
 
Write-Output "Initializing context and retrieving automation variables..."

# Automation variables
$storageAccountSink = Get-AutomationVariable -Name "AzureOptimization_StorageSink"
$storageAccountSinkRG = Get-AutomationVariable -Name "AzureOptimization_StorageSinkRG"
$cloudEnvironment = Get-AutomationVariable -Name "AzureOptimization_CloudEnvironment" -ErrorAction SilentlyContinue
if (-not $cloudEnvironment) { $cloudEnvironment = "AzureCloud" }
$subscriptionId = Get-AutomationVariable -Name "AzureOptimization_LogAnalyticsWorkspaceSubId"

Write-Output "Connecting to Azure with environment: $cloudEnvironment and subscription: $subscriptionId..."
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
Set-AzContext -SubscriptionName $subscriptionId

Write-Output "Retrieving storage account context for $storageAccountSink in resource group $storageAccountSinkRG..."
$sa = Get-AzStorageAccount -ResourceGroupName $storageAccountSinkRG -Name $storageAccountSink
$saCtx = New-AzStorageContext -StorageAccountName $storageAccountSink -UseConnectedAccount -Environment $cloudEnvironment

#endregion

#region --- Helper Functions ---

function Invoke-WithRetry {
    param(
        [scriptblock] $Script,
        [int] $MaxRetries = 3,
        [int] $SleepSeconds = 30
    )
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            Write-Output "Attempt $i executing script block..."
            return & $Script
        } 
        catch {
            Write-Warning "Attempt $i failed: $($_.Exception.Message)"
            if ($i -lt $MaxRetries) { Start-Sleep -Seconds $SleepSeconds }
        }
    }
    throw "Operation failed after $MaxRetries attempts."
}

function Get-QueryResult{   
    param(
    [string]$query
)
    $count = 1000
    $finalResult = @()
    while ($count -eq 1000) {
        if ($finalResult.length -gt 0) {
            $result = Search-AzGraph -Query $query -First 1000 -Skip $finalResult.length -UseTenantScope   
        } else {
            $result = Search-AzGraph -Query $query -First 1000 -UseTenantScope
        }
        $count = $result.Count
        $finalResult += $result
    }
    return $finalResult
}

function Is-OffHours {
    param([datetime] $Timestamp)
    return ($Timestamp.DayOfWeek -in @("Saturday", "Sunday") -or ($Timestamp.Hour -ge 18 -and $Timestamp.Hour -le 23) -or ($Timestamp.Hour -ge 0 -and $Timestamp.Hour -le 7))
}

#endregion

#region --- Target Subscriptions ---

Write-Output "Retrieving subscription IDs for environment: $env"
$subscriptionIds = @("0c61ea68-7c38-4824-ba78-a32a690b8305",
"292dd957-849f-41de-8c9c-4e6f7ab8b21f",
"791181b2-bba9-42e7-8ff4-4a57973d5724",
"9ecfa923-c406-4a0d-a30e-dd888013baa5",
"7f19cc6e-5250-4a2d-8719-4b69898cb69f")
$subscriptionIdsStr = ""
for ($i=0; $i -lt $subscriptionIds.Count; $i++) {
    $subscriptionIdsStr += ("'" + $subscriptionIds[$i] + "'")
    if ($i -lt $subscriptionIds.Count - 1) {
        $subscriptionIdsStr += ", "
    }
}
$subscriptionFilter = "(" + $subscriptionIdsStr + ")"

# $subscriptionIds += (Get-AzManagementGroupSubscription -GroupId $env -WarningAction SilentlyContinue).Id | ForEach-Object { $_.Split("/")[6] }
# $subscriptionFilter = "(""" + $subscriptionIds + """)"

Write-Output "Target subscriptions: $subscriptionFilter"


#endregion

#region --- Collect VM & VMSS Resources ---

$queryVmss = "resources | where type =~ 'microsoft.compute/virtualmachinescalesets' and subscriptionId in $subscriptionFilter | order by subscriptionId desc"
Write-Output("Querying VMSS resources... " + $queryVmss)

$vmsss = Get-QueryResult($queryVmss)
$currentSubscription = (Get-AzContext).Subscription

Write-Output "Retrieving VM instances from VMSS..."
$vmssVms = foreach ($vmss in $vmsss) {
        if ($currentSubscription.Id -ne $vmss.subscriptionId) {
            Write-Output "Switching context to subscription: $($vmss.subscriptionId)"
            # Select-AzSubscription -SubscriptionId $vmss.subscriptionId
            Set-AzContext -SubscriptionId $vmss.subscriptionId
            $currentSubscription = (Get-AzContext).Subscription
        }
    Get-AzVmssVM -VMScaleSetName $vmss.Id.Split("/")[8] -ResourceGroupName $vmss.Id.Split("/")[4]
}

$queryVms = "resources | where type =~ 'microsoft.compute/virtualmachines' and subscriptionId in $subscriptionFilter | order by subscriptionId desc"
Write-Output "Querying standalone VMs..."
$allVms = Get-QueryResult($queryVms)

$vmssVmIds = $vmssVms | ForEach-Object { $_.Id }
$standaloneVms = $allVms | Where-Object { $vmssVmIds -notcontains $_.Id }

Write-Output "Selecting resources based on vmssOrVm parameter: $vmssOrVm"
$resourceList = if ($vmssOrVm -eq "vmss") { $vmsss } else { $standaloneVms }

#endregion

#region --- Analyze Utilization & Costs ---

Write-Output "Analyzing utilization and costs..."

$utilResults = @()
$today = (Get-Date).ToUniversalTime()
$startDate = $today.AddDays(-30)
$endDate = $today.AddDays(-1)

foreach ($item in $resourceList) {
    Write-Output "Processing resource: $($item.Id)"
    if ($currentSubscription.Id -ne $item.subscriptionId)
    {
        Write-Output "Switching context to subscription: $($item.subscriptionId)"
        # Select-AzSubscription -SubscriptionId $item.subscriptionId
        Set-AzContext -SubscriptionId $item.subscriptionId
        $currentSubscription = (Get-AzContext).Subscription
    }
    # Set-AzContext -SubscriptionId $item.subscriptionId
    $metrics = Invoke-WithRetry { Get-AzMetric -ResourceId $item.Id -MetricName 'Percentage CPU' -TimeGrain 00:01:00 -AggregationType Average -StartTime $startDate -EndTime $today }
    
    $costs = Invoke-WithRetry { Get-AzConsumptionUsageDetail -InstanceId $item.Id -StartDate $startDate.ToString("yyyy-MM-dd") -EndDate $endDate.ToString("yyyy-MM-dd") }
    $offHoursData = $metrics.Timeseries.Data | Where-Object { Is-OffHours -Timestamp $_.TimeStamp }

    $avgUtil = ($offHoursData | Where-Object { $_.Average -ne $null } | Measure-Object -Property Average -Average).Average
    $shutOffPct = ($offHoursData | Where-Object { $_.Average -eq $null }).Count / ($offHoursData.Count)

    # Write-Output "Off-hours utilization for $($item.Name): Average = $avgUtil%, ShutOff = $([math]::Round($shutOffPct * 100, 2))%"

    $monthlyCost = ($costs.PretaxCost | Measure-Object -Sum).Sum
    $usageQuantity = ($costs.UsageQuantity | Measure-Object -Sum).Sum
    $savingsEstimate = ((10 * 5 + 24 * 2) / (24 * 7)) * $monthlyCost

    if ($avgUtil -lt 10 -and $shutOffPct -lt 0.95) {
        # Write-Output "Resource $($item.Name) is underutilized during off-hours. Adding to results."
        $utilResults += [pscustomobject]@{
            ResourceGroupName          = $item.resourceGroup
            VM                         = $item.Name
            Cloud                      = "AzureCloud"
            Type                       = $item.Type
            ResourceId                 = $item.Id
            Location                   = $item.Location
            Tags                       = $item.Tags
            OffHoursUtilizationAverage = $avgUtil
            ShutOffPercentage          = $shutOffPct
            MonthlyCosts               = $monthlyCost
            SavingsAmount              = $savingsEstimate
            UsageQuantitySum           = $usageQuantity
            FitScore                   = 5
            SubscriptionName           = (Get-AzContext).Subscription.Name
            SubscriptionGuid           = $item.subscriptionId
            Properties                 = $item.Properties
            Sku                        = $item.Properties.hardwareProfile.vmSize
        }
    }
}

Write-Output "Completed analysis. Total underutilized resources found: $($utilResults.Count)"

#endregion

#region --- Export & Upload ---

Write-Output "Exporting results and uploading to Blob Storage..."

$timestamp = $today.ToString("yyyyMMdd")
$jsonFile = "$timestamp-underutilized-$vmssOrVm-$env.json"
$csvFile = "$timestamp-underutilized-$vmssOrVm-$env.csv"

$utilResults | ConvertTo-Json -Depth 3 | Out-File $jsonFile
Write-Output "Saved JSON output to $jsonFile"
$utilResults | Export-Csv -NoTypeInformation -Path $csvFile
Write-Output "Saved CSV output to $csvFile"

Set-AzStorageBlobContent -File $csvFile -Container 'vmsunderutilizedoffhoursexports' -Blob $csvFile -Properties @{"ContentType" = "text/csv"} -Context $saCtx -Force

Write-Output "[$(Get-Date -Format o)] Uploaded $csvFile to Blob Storage."

Remove-Item -Path $csvFile -Force
Remove-Item -Path $jsonFile -Force

Write-Output "Cleaned up local files."

#endregion
