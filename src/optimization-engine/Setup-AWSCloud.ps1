<#
.SYNOPSIS
Configure AWS cloud data collection for the RAVL Optimization Engine.

.DESCRIPTION
Sets up the automation variables, storage container, and schedules required to
collect cost and utilisation data from AWS via a Distributor VM running the
finops-aws export scripts. The Distributor VM must already be deployed before
running this script.

.PARAMETER ResourceGroupName
The resource group containing the deployment. If not provided, reads from
ravl-oe-config.json in the same directory.

.EXAMPLE
.\Setup-AWSCloud.ps1

Interactive setup using config from ravl-oe-config.json.

.EXAMPLE
.\Setup-AWSCloud.ps1 -ResourceGroupName "ravl-optimization-engine"
#>

#Requires -Version 7.0

param (
    [string] $ResourceGroupName = ""
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------

$configPath = Join-Path $PSScriptRoot "ravl-oe-config.json"
$config     = @{}

if (Test-Path $configPath) {
    $json = Get-Content $configPath -Raw | ConvertFrom-Json
    foreach ($prop in $json.PSObject.Properties) {
        $config[$prop.Name] = $prop.Value
    }
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $ResourceGroupName = $config["ResourceGroupName"]
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $ResourceGroupName = Read-Host "Resource group name"
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host "  RAVL Optimization Engine — AWS Setup" -ForegroundColor Cyan
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Locate Automation Account
# ---------------------------------------------------------------------------

$aaName = $config["AutomationAccountName"]

if (-not $aaName) {
    Write-Host "  Discovering Automation Account in '$ResourceGroupName'..." -ForegroundColor DarkGray
    $aaResources = Get-AzResource -ResourceGroupName $ResourceGroupName `
                       -ResourceType "Microsoft.Automation/automationAccounts" -ErrorAction SilentlyContinue
    if ($aaResources.Count -eq 1) {
        $aaName = $aaResources[0].Name
        Write-Host "  Found: $aaName" -ForegroundColor DarkGray
    } elseif ($aaResources.Count -gt 1) {
        Write-Host "  Multiple Automation Accounts found — specify one:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $aaResources.Count; $i++) {
            Write-Host "    [$i] $($aaResources[$i].Name)"
        }
        $idx    = [int](Read-Host "  Enter number")
        $aaName = $aaResources[$idx].Name
    } else {
        Write-Host "  [ERROR] No Automation Account found in '$ResourceGroupName'." -ForegroundColor Red
        Write-Host "          Run Install-RAVLOptEngine.ps1 first." -ForegroundColor Yellow
        exit 1
    }
}

try {
    $aa = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $aaName -ErrorAction Stop
    Write-Host "  [OK] Automation Account: $aaName" -ForegroundColor Green
} catch {
    Write-Host "  [ERROR] Automation Account '$aaName' not found: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Check if AWS already enabled
# ---------------------------------------------------------------------------

$awsEnabledVar = Get-AzAutomationVariable -ResourceGroupName $ResourceGroupName `
                     -AutomationAccountName $aaName -Name "AWSEnabled" -ErrorAction SilentlyContinue

if ($awsEnabledVar -and $awsEnabledVar.Value -eq "true") {
    Write-Host ""
    Write-Host "  AWS integration is already enabled." -ForegroundColor Yellow
    $overwrite = Read-Host "  Reconfigure? [y/N]"
    if ($overwrite.Trim().ToLower() -notin @("y", "yes")) {
        Write-Host "  No changes made." -ForegroundColor DarkGray
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Distributor VM requirement check
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  The AWS integration requires a Distributor VM — a Linux VM in Azure" -ForegroundColor Cyan
Write-Host "  that runs the finops-aws export scripts via the Hybrid Runbook Worker." -ForegroundColor Cyan
Write-Host ""
$hasVM = Read-Host "  Do you have a Distributor VM deployed? [y/N]"

if ($hasVM.Trim().ToLower() -notin @("y", "yes")) {
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Yellow
    Write-Host "  Distributor VM Requirements" -ForegroundColor Yellow
    Write-Host "  ============================================================" -ForegroundColor Yellow
    Write-Host "  1. Deploy a Linux VM (Ubuntu 20.04+ recommended) in Azure" -ForegroundColor White
    Write-Host "  2. Install the Azure Automation Hybrid Runbook Worker extension" -ForegroundColor White
    Write-Host "  3. Install the AWS CLI and configure credentials" -ForegroundColor White
    Write-Host "  4. Clone the finops-aws scripts to /home/AZIGMADMIN/finops-aws/" -ForegroundColor White
    Write-Host "  5. Re-run this script once the VM is ready" -ForegroundColor White
    Write-Host "  ============================================================" -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# ---------------------------------------------------------------------------
# Gather VM details
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  Distributor VM Configuration" -ForegroundColor Cyan
Write-Host "  ----------------------------" -ForegroundColor DarkGray

$vmName = Read-Host "  VM name"
$vmRG   = Read-Host "  VM resource group [default: $ResourceGroupName]"
if ([string]::IsNullOrWhiteSpace($vmRG)) { $vmRG = $ResourceGroupName }

$vmLocInput = Read-Host "  VM location [default: canadacentral]"
if ([string]::IsNullOrWhiteSpace($vmLocInput)) { $vmLocInput = "canadacentral" }

$awsPathInput = Read-Host "  AWS scripts path [default: /home/AZIGMADMIN/finops-aws/AWS_Exporting]"
if ([string]::IsNullOrWhiteSpace($awsPathInput)) { $awsPathInput = "/home/AZIGMADMIN/finops-aws/AWS_Exporting" }

# ---------------------------------------------------------------------------
# Verify VM
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  Verifying VM '$vmName' in '$vmRG'..." -ForegroundColor DarkGray
try {
    $vm = Get-AzVM -ResourceGroupName $vmRG -Name $vmName -ErrorAction Stop
    Write-Host "  [OK] VM found: $vmName ($($vm.Location))" -ForegroundColor Green
} catch {
    Write-Host "  [ERROR] VM '$vmName' not found in '$vmRG': $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Set automation variables
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  Setting automation variables..." -ForegroundColor DarkGray

$variablesToSet = @{
    "AWSEnabled"           = "true"
    "DistributorVmName"    = $vmName
    "DistributorVmRG"      = $vmRG
    "DistributorVmLocation"= $vmLocInput
    "AWSScriptsPath"       = $awsPathInput
}

foreach ($varName in $variablesToSet.Keys) {
    $varValue   = $variablesToSet[$varName]
    $existingVar = Get-AzAutomationVariable -ResourceGroupName $ResourceGroupName `
                       -AutomationAccountName $aaName -Name $varName -ErrorAction SilentlyContinue
    try {
        if ($existingVar) {
            Set-AzAutomationVariable -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $aaName -Name $varName -Value $varValue -Encrypted $false | Out-Null
        } else {
            New-AzAutomationVariable -ResourceGroupName $ResourceGroupName `
                -AutomationAccountName $aaName -Name $varName -Value $varValue -Encrypted $false | Out-Null
        }
        Write-Host "  [OK] $varName = $varValue" -ForegroundColor Green
    } catch {
        Write-Host "  [WARN] Could not set $varName`: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Create awsexports container
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  Checking storage container 'awsexports'..." -ForegroundColor DarkGray

$saName = $config["StorageAccountName"]
if (-not $saName) {
    $saResources = Get-AzResource -ResourceGroupName $ResourceGroupName `
                       -ResourceType "Microsoft.Storage/storageAccounts" -ErrorAction SilentlyContinue
    if ($saResources.Count -gt 0) { $saName = $saResources[0].Name }
}

if ($saName) {
    try {
        $storageCtx = (Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $saName -ErrorAction Stop).Context
        $existing   = Get-AzStorageContainer -Name "awsexports" -Context $storageCtx -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-AzStorageContainer -Name "awsexports" -Context $storageCtx -Permission Off | Out-Null
            Write-Host "  [OK] Container 'awsexports' created" -ForegroundColor Green
        } else {
            Write-Host "  [OK] Container 'awsexports' already exists" -ForegroundColor Green
        }
    } catch {
        Write-Host "  [WARN] Could not create container: $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [WARN] Storage account not found — skipping container creation" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Enable AWS schedules
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  Enabling AWS schedules..." -ForegroundColor DarkGray

try {
    $allSchedules = Get-AzAutomationSchedule -ResourceGroupName $ResourceGroupName `
                        -AutomationAccountName $aaName -ErrorAction Stop
    $awsSchedules = $allSchedules | Where-Object { $_.Name -like "*AWS*" }

    if ($awsSchedules.Count -eq 0) {
        Write-Host "  [WARN] No AWS schedules found. Runbooks may not yet be linked to schedules." -ForegroundColor Yellow
    } else {
        foreach ($sched in $awsSchedules) {
            try {
                Set-AzAutomationSchedule -ResourceGroupName $ResourceGroupName `
                    -AutomationAccountName $aaName -Name $sched.Name -IsEnabled $true | Out-Null
                Write-Host "  [OK] Enabled schedule: $($sched.Name)" -ForegroundColor Green
            } catch {
                Write-Host "  [WARN] Could not enable '$($sched.Name)': $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
} catch {
    Write-Host "  [WARN] Could not retrieve schedules: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Offer test export
# ---------------------------------------------------------------------------

Write-Host ""
$runTest = Read-Host "  Run a test AWS export now (Export-AWSUnderutilizedEC2Instances)? [y/N]"

if ($runTest.Trim().ToLower() -in @("y", "yes")) {
    $testRunbook = "Export-AWSUnderutilizedEC2Instances"
    try {
        $rb = Get-AzAutomationRunbook -ResourceGroupName $ResourceGroupName `
                  -AutomationAccountName $aaName -Name $testRunbook -ErrorAction SilentlyContinue
        if ($rb) {
            Write-Host "  Starting $testRunbook..." -ForegroundColor DarkGray
            $job = Start-AzAutomationRunbook -ResourceGroupName $ResourceGroupName `
                       -AutomationAccountName $aaName -Name $testRunbook -ErrorAction Stop
            Write-Host "  [OK] Test job started: $($job.JobId)" -ForegroundColor Green
            Write-Host "       Monitor in the Azure portal or run Validate-Deployment.ps1 in a few minutes." -ForegroundColor DarkGray
        } else {
            Write-Host "  [WARN] Runbook '$testRunbook' not found — upload runbooks first." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  [WARN] Could not start test export: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host "  AWS Setup Complete" -ForegroundColor Green
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Automation account : $aaName" -ForegroundColor White
Write-Host "  Distributor VM     : $vmName ($vmRG)" -ForegroundColor White
Write-Host "  Scripts path       : $awsPathInput" -ForegroundColor White
Write-Host "  Storage container  : awsexports" -ForegroundColor White
Write-Host ""
Write-Host "  AWS data collection will run on the next scheduled cycle." -ForegroundColor DarkGray
Write-Host "  Run Validate-Deployment.ps1 to confirm the engine is healthy." -ForegroundColor DarkGray
Write-Host ""
