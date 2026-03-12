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
$awsScriptsPath = Get-AutomationVariable -Name "AzureOptimization_AWSScriptsPath" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($awsScriptsPath)) { $awsScriptsPath = "/home/AZIGMADMIN/finops-aws/AWS_Exporting" }
$ts = Get-Date -Format 'yyyyMMddHHmmss'

Write-Output "$awsScriptsPath/logs"

$script = @"
cd $awsScriptsPath

# Ensure logs directory exists
mkdir -p logs

# Run the AWS idle Elastic Beanstalk Environment export script
./export-aws-idle-elastic-beanstalk-environments.sh >> logs/aws-idle-elastic-beanstalk-environments_$ts.txt 2>&1
"@

Write-Output "Exporting AWS Idle Elastic Beanstalk Environments"
Write-Output "Executing script on VM: $vmName"
Write-Output "Script path: $awsScriptsPath"
Write-Output "Log file: logs/aws-idle-elastic-beanstalk-environments_$ts.txt"

Set-AzVMRunCommand -ResourceGroupName $rg -VMName $vmName -Location $vmLocation -RunCommandName "ExportAWSIdleElasticBeanstalkEnvironments" –SourceScript $script

Write-Output "Completed Exporting AWS Idle Elastic Beanstalk Environments"
Write-Output "Data exported to Azure Storage and CSV/JSON files generated"
