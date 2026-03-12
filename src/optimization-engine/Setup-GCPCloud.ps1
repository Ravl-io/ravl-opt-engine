<#
.SYNOPSIS
Configure GCP cloud data collection for the RAVL Optimization Engine.

.DESCRIPTION
Sets up the automation variables, storage container, and schedules required to
collect cost and utilisation data from GCP via a Distributor VM running the
finops-gcp export scripts. The Distributor VM must already be deployed and have
the gcloud and bq CLIs installed before running this script.

NOTE: The GCP-IngestFOCUS.ps1 runbook requires a Hybrid Worker with both
gcloud (Google Cloud SDK) and bq (BigQuery CLI) installed and authenticated.
Standard Azure Automation sandbox workers cannot execute these runbooks.

.PARAMETER ResourceGroupName
The resource group containing the deployment. If not provided, reads from
ravl-oe-config.json in the same directory.

.EXAMPLE
.\Setup-GCPCloud.ps1

Interactive setup using config from ravl-oe-config.json.

.EXAMPLE
.\Setup-GCPCloud.ps1 -ResourceGroupName "ravl-optimization-engine"
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
Write-Host "  RAVL Optimization Engine — GCP Setup" -ForegroundColor Cyan
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Hybrid Worker warning
# ---------------------------------------------------------------------------

Write-Host "  IMPORTANT: GCP integration requires a Hybrid Runbook Worker VM" -ForegroundColor Yellow
Write-Host "  with the following tools installed and authenticated:" -ForegroundColor Yellow
Write-Host "    - gcloud (Google Cloud SDK)" -ForegroundColor Yellow
Write-Host "    - bq    (BigQuery CLI)" -ForegroundColor Yellow
Write-Host "  GCP-IngestFOCUS.ps1 CANNOT run on standard Azure Automation workers." -ForegroundColor Yellow
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
# Check if GCP already enabled
# ---------------------------------------------------------------------------

$gcpEnabledVar = Get-AzAutomationVariable -ResourceGroupName $ResourceGroupName `
                     -AutomationAccountName $aaName -Name "GCPEnabled" -ErrorAction SilentlyContinue

if ($gcpEnabledVar -and $gcpEnabledVar.Value -eq "true") {
    Write-Host ""
    Write-Host "  GCP integration is already enabled." -ForegroundColor Yellow
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
Write-Host "  The GCP integration requires a Distributor VM — a Linux VM in Azure" -ForegroundColor Cyan
Write-Host "  that runs the finops-gcp export scripts via the Hybrid Runbook Worker." -ForegroundColor Cyan
Write-Host ""
$hasVM = Read-Host "  Do you have a Distributor VM deployed with gcloud and bq installed? [y/N]"

if ($hasVM.Trim().ToLower() -notin @("y", "yes")) {
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Yellow
    Write-Host "  Distributor VM Requirements" -ForegroundColor Yellow
    Write-Host "  ============================================================" -ForegroundColor Yellow
    Write-Host "  1. Deploy a Linux VM (Ubuntu 20.04+ recommended) in Azure" -ForegroundColor White
    Write-Host "  2. Install the Azure Automation Hybrid Runbook Worker extension" -ForegroundColor White
    Write-Host "  3. Install Google Cloud SDK: https://cloud.google.com/sdk/docs/install" -ForegroundColor White
    Write-Host "  4. Run 'gcloud auth login' and 'gcloud auth application-default login'" -ForegroundColor White
    Write-Host "  5. Install BigQuery CLI (included with Google Cloud SDK)" -ForegroundColor White
    Write-Host "  6. Clone the finops-gcp scripts to /home/AZIGMADMIN/finops-gcp/" -ForegroundColor White
    Write-Host "  7. Re-run this script once the VM is ready" -ForegroundColor White
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

$gcpPathInput = Read-Host "  GCP scripts path [default: /home/AZIGMADMIN/finops-gcp/GCP_Exporting]"
if ([string]::IsNullOrWhiteSpace($gcpPathInput)) { $gcpPathInput = "/home/AZIGMADMIN/finops-gcp/GCP_Exporting" }

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
    "GCPEnabled"           = "true"
    "DistributorVmName"    = $vmName
    "DistributorVmRG"      = $vmRG
    "DistributorVmLocation"= $vmLocInput
    "GCPScriptsPath"       = $gcpPathInput
}

foreach ($varName in $variablesToSet.Keys) {
    $varValue    = $variablesToSet[$varName]
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
# Create gcpexports container
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  Checking storage container 'gcpexports'..." -ForegroundColor DarkGray

$saName = $config["StorageAccountName"]
if (-not $saName) {
    $saResources = Get-AzResource -ResourceGroupName $ResourceGroupName `
                       -ResourceType "Microsoft.Storage/storageAccounts" -ErrorAction SilentlyContinue
    if ($saResources.Count -gt 0) { $saName = $saResources[0].Name }
}

if ($saName) {
    try {
        $storageCtx = (Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $saName -ErrorAction Stop).Context
        $existing   = Get-AzStorageContainer -Name "gcpexports" -Context $storageCtx -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-AzStorageContainer -Name "gcpexports" -Context $storageCtx -Permission Off | Out-Null
            Write-Host "  [OK] Container 'gcpexports' created" -ForegroundColor Green
        } else {
            Write-Host "  [OK] Container 'gcpexports' already exists" -ForegroundColor Green
        }
    } catch {
        Write-Host "  [WARN] Could not create container: $($_.Exception.Message)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  [WARN] Storage account not found — skipping container creation" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Enable GCP schedules
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "  Enabling GCP schedules..." -ForegroundColor DarkGray

try {
    $allSchedules = Get-AzAutomationSchedule -ResourceGroupName $ResourceGroupName `
                        -AutomationAccountName $aaName -ErrorAction Stop
    $gcpSchedules = $allSchedules | Where-Object { $_.Name -like "*GCP*" }

    if ($gcpSchedules.Count -eq 0) {
        Write-Host "  [WARN] No GCP schedules found. Runbooks may not yet be linked to schedules." -ForegroundColor Yellow
    } else {
        foreach ($sched in $gcpSchedules) {
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
$runTest = Read-Host "  Run a test GCP export now (Export-GCPUnderutilizedVMs)? [y/N]"

if ($runTest.Trim().ToLower() -in @("y", "yes")) {
    $testRunbook = "Export-GCPUnderutilizedVMs"
    try {
        $rb = Get-AzAutomationRunbook -ResourceGroupName $ResourceGroupName `
                  -AutomationAccountName $aaName -Name $testRunbook -ErrorAction SilentlyContinue
        if ($rb) {
            Write-Host "  Starting $testRunbook..." -ForegroundColor DarkGray
            $job = Start-AzAutomationRunbook -ResourceGroupName $ResourceGroupName `
                       -AutomationAccountName $aaName -Name $testRunbook -ErrorAction Stop
            Write-Host "  [OK] Test job started: $($job.JobId)" -ForegroundColor Green
            Write-Host "       Monitor in the Azure portal or run Validate-Deployment.ps1 in a few minutes." -ForegroundColor DarkGray
            Write-Host "       NOTE: This job will run on a Hybrid Worker — ensure the VM is online." -ForegroundColor Yellow
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
Write-Host "  GCP Setup Complete" -ForegroundColor Green
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Automation account : $aaName" -ForegroundColor White
Write-Host "  Distributor VM     : $vmName ($vmRG)" -ForegroundColor White
Write-Host "  Scripts path       : $gcpPathInput" -ForegroundColor White
Write-Host "  Storage container  : gcpexports" -ForegroundColor White
Write-Host ""
Write-Host "  REMINDER: GCP-IngestFOCUS.ps1 requires the Hybrid Worker VM to be" -ForegroundColor Yellow
Write-Host "  online with gcloud and bq authenticated. Standard workers will fail." -ForegroundColor Yellow
Write-Host ""
Write-Host "  GCP data collection will run on the next scheduled cycle." -ForegroundColor DarkGray
Write-Host "  Run Validate-Deployment.ps1 to confirm the engine is healthy." -ForegroundColor DarkGray
Write-Host ""
