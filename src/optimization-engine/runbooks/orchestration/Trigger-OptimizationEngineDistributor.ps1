param(
  [Parameter(Mandatory=$true)]
  [string] $tasks
)
$ErrorActionPreference = 'Stop'

# Task execution order is determined  by the order of the $tasks
$validTasks = @("monitor", "distributor", "statusmover", "exemptvm", "schedulevm", "healthcheck")
$tasksToRun = $tasks -split "," | ForEach-Object { $_.Trim() }
$invalidTasks = $tasksToRun | Where-Object { $_ -notin $validTasks }

if ($invalidTasks.Count -gt 0) {
  Write-Error "Invalid task(s) specified: $($invalidTasks -join ', '). Valid tasks are: $($validTasks -join ', ')"
  exit 1
}

$subscriptionId = Get-AutomationVariable -Name "AzureOptimization_SubscriptionId" -ErrorAction Stop
Connect-AzAccount -Identity -Subscription $subscriptionId -EnvironmentName 'AzureCloud'

# Azure Key Vault Setup
$keyVaultName = Get-AutomationVariable -Name "AzureOptimization_KeyVaultName" -ErrorAction Stop

# Python Environment Variable Setup
$azurePortalUrl = Get-AutomationVariable -Name "AzureOptimization_AzurePortalUrl" -ErrorAction Stop

# Db Connection String
$sqlserverCredential = Get-AutomationPSCredential -Name "AzureOptimization_SQLServerCredential" -ErrorAction Stop
$dbUser = $sqlserverCredential.UserName
$dbPassword = $sqlserverCredential.GetNetworkCredential().Password

$dbServer = Get-AutomationVariable -Name "AzureOptimization_SQLServerHostname" -ErrorAction Stop
$dbName = Get-AutomationVariable -Name "AzureOptimization_SQLServerDatabase" -ErrorAction Stop
$dbConnectionString = "Driver={ODBC Driver 18 for SQL Server};Server=tcp:$dbServer,1433;Database=$dbName;Uid=$dbUser;Pwd=$dbPassword;TrustServerCertificate=yes;"

$jiraUrl = Get-AutomationVariable -Name "AzureOptimization_JiraUrl" -ErrorAction Stop
$jiraUserName = Get-AutomationVariable -Name "AzureOptimization_JiraUserName" -ErrorAction Stop

# required way to get securestring value using PS 5.1
$jiraAuthTokenKey = Get-AutomationVariable -Name "AzureOptimization_JiraAuthTokenKey" -ErrorAction Stop
$jiraAuthTokenSecret = (Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $jiraAuthTokenKey -ErrorAction Stop).SecretValue
$jiraBSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($jiraAuthTokenSecret)
$jiraAuthtoken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($jiraBSTR)
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($jiraBSTR)

$jiraProjectKey = Get-AutomationVariable -Name "AzureOptimization_JiraProjectKey" -ErrorAction Stop

# Optimization Engine Setup
$vmName = Get-AutomationVariable -Name "AzureOptimization_DistributorVmName" -ErrorAction Stop
$rg = Get-AutomationVariable -Name "AzureOptimization_ResourceGroup" -ErrorAction Stop
$targetPath = "/home/finops/install"

# Robust wrapper for RunCommand with 409 handling (exponential backoff)
function Invoke-RunCmdSafe {
  param(
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $VMName,
    [Parameter(Mandatory)] [string] $ScriptString,
    [int] $MaxRetries = 8,
    [int] $InitialDelaySeconds = 2,
    [int] $MaxDelaySeconds = 30
  )
  $delay = $InitialDelaySeconds
  for ($i = 0; $i -lt $MaxRetries; $i++) {
    try {
      return Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName `
        -CommandId 'RunShellScript' -ScriptString $ScriptString -ErrorAction Stop
    # return Set-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName -Location "canadacentral" -RunCommandName "DistributorRun" –SourceScript $ScriptString -TimeoutInSecond 3300 -ErrorAction Stop

    } catch {
      $msg = $_.Exception.Message
      # 409 Conflict / "execution in progress"
      if ($msg -match '409' -or $msg -match 'in progress' -or $msg -match 'Run command extension execution is in progress') {
        Start-Sleep -Seconds $delay
        $delay = [Math]::Min($delay * 2, $MaxDelaySeconds)
        continue
      }
      throw  # different error: bubble up
    }
  }
  throw "RunCommand busy after $MaxRetries retries."
}
Write-Output "$targetPath/logs"
# Write-Output ("export AZURE_PORTAL_URL='{0}'; export DB_CONNECTION_STRING='{1}'; export JIRA_URL='{2}'; export JIRA_USERNAME='{3}'; export JIRA_AUTH_TOKEN='{4}'; export JIRA_PROJECT_KEY='{5}'; export LOG_DIR='{6}'" -f `
#   ($azurePortalUrl     -replace "'", "'\''"), `
#   ($dbConnectionString -replace "'", "'\''"), `
#   ($jiraUrl            -replace "'", "'\''"), `
#   ($jiraUserName       -replace "'", "'\''"), `
#   ($jiraAuthToken      -replace "'", "'\''"), `
#   ($jiraProjectKey     -replace "'", "'\''"), `
#   (("$targetPath/logs")-replace "'", "'\''") )

$script = @"
cd $targetPath

source .venv/bin/activate

# Set Environment Variables
export AZURE_PORTAL_URL="$azurePortalUrl"
export DB_CONNECTION_STRING="$dbConnectionString"
export JIRA_URL="$jiraUrl"
export JIRA_USERNAME="$jiraUserName"
export JIRA_AUTH_TOKEN="$jiraAuthToken"
export JIRA_PROJECT_KEY="$jiraProjectKey"
export LOG_DIR="$targetPath/logs"

optimization-distributor --task $($tasksToRun -join ',')
# optimization-distributor --help
"@

Write-Output "Start Optimization Engine..."
$null = Invoke-RunCmdSafe -ResourceGroupName $rg -VMName $vmName -ScriptString $script
Write-Output "Completed Optimization Engine"
