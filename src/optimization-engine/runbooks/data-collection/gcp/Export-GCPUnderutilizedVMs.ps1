$ErrorActionPreference = 'Stop'

$subscriptionId = Get-AutomationVariable -Name "AzureOptimization_SubscriptionId" -ErrorAction Stop
$cloudEnvironment = Get-AutomationVariable -Name "AzureOptimization_CloudEnvironment" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($cloudEnvironment)) { $cloudEnvironment = "AzureCloud" }
$authenticationOption = Get-AutomationVariable -Name "AzureOptimization_AuthenticationOption" -ErrorAction SilentlyContinue
$uamiClientID = Get-AutomationVariable -Name "AzureOptimization_UAMIClientID" -ErrorAction SilentlyContinue

switch ($authenticationOption) {
    "UserAssignedManagedIdentity" {
        Connect-AzAccount -Identity -EnvironmentName $cloudEnvironment -AccountId $uamiClientID
        break
    }
    Default { #ManagedIdentity
        Connect-AzAccount -Identity -EnvironmentName $cloudEnvironment
        break
    }
}
Set-AzContext -SubscriptionId $subscriptionId | Out-Null

# Export Script Setup
$vmName = Get-AutomationVariable -Name "AzureOptimization_DistributorVmName" -ErrorAction Stop
$rg = Get-AutomationVariable -Name "AzureOptimization_DistributorVmRG" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($rg)) {
    $rg = Get-AutomationVariable -Name "AzureOptimization_ResourceGroup" -ErrorAction Stop
}
$vmLocation = Get-AutomationVariable -Name "AzureOptimization_DistributorVmLocation" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($vmLocation)) { $vmLocation = "canadacentral" }
$gcpScriptsPath = Get-AutomationVariable -Name "AzureOptimization_GCPScriptsPath" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($gcpScriptsPath)) { $gcpScriptsPath = "/home/AZIGMADMIN/finops-gcp/GCP_Exporting" }
$ts = Get-Date -Format 'yyyyMMddHHmmss'

Write-Output "$gcpScriptsPath/logs"

$script = @"
cd $gcpScriptsPath

./export-underutilized-gcp-vms.sh >> logs/gcp-underutilized-vms_$ts.txt 2>&1
"@

Write-Output "Exporting GCP Underutilized VMs"
Write-Output "Excecuting $script"

# Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName $vmName -CommandId 'RunShellScript' -ScriptString $script -ErrorAction Stop
Set-AzVMRunCommand -ResourceGroupName $rg -VMName $vmName -Location $vmLocation -RunCommandName "ExportGCPUnderutilizedVMs" –SourceScript $script -TimeoutInSecond 9800

Write-Output "Completed Exporting GCP Underutilized VMs"
