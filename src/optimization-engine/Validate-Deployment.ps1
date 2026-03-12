<#
.SYNOPSIS
Health check script for the RAVL Optimization Engine deployment.

.DESCRIPTION
Validates that all required Azure resources, runbooks, automation variables,
storage containers, SQL connectivity, and schedules are correctly deployed
and operational. Optionally runs a live export test.

.PARAMETER ResourceGroupName
The resource group containing the deployment. If not provided, reads from
ravl-oe-config.json in the same directory.

.PARAMETER Quick
Skip the live export test (checks 1-6 only).

.EXAMPLE
.\Validate-Deployment.ps1

Runs all 8 health checks using config from ravl-oe-config.json.

.EXAMPLE
.\Validate-Deployment.ps1 -ResourceGroupName "ravl-optimization-engine" -Quick

Runs checks 1-6 only against the specified resource group.
#>

#Requires -Version 7.0

param (
    [string] $ResourceGroupName = "",
    [switch] $Quick
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Check tracking
# ---------------------------------------------------------------------------

$script:CheckResults = [System.Collections.Generic.List[hashtable]]::new()

function Write-Check {
    param (
        [string] $Name,
        [bool]   $Passed,
        [string] $Detail = "",
        [string] $Fix    = ""
    )

    $status = if ($Passed) { "[PASS]" } else { "[FAIL]" }
    $color  = if ($Passed) { "Green"  } else { "Red"   }

    Write-Host "$status $Name" -ForegroundColor $color
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor DarkGray }
    if (-not $Passed -and $Fix) { Write-Host "  FIX: $Fix" -ForegroundColor Yellow }

    $script:CheckResults.Add(@{
        Name   = $Name
        Passed = $Passed
        Detail = $Detail
        Fix    = $Fix
    })
}

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
# Derive resource names from config (same logic as installer)
# ---------------------------------------------------------------------------

$aaName   = $config["AutomationAccountName"]
$saName   = $config["StorageAccountName"]
$sqlName  = $config["SqlServerName"]
$lawName  = $config["WorkspaceName"]
$prefix   = $config["NamePrefix"]

if (-not $aaName  -and $prefix -and $prefix -ne "EmptyNamePrefix") { $aaName  = "${prefix}aa"  }
if (-not $saName  -and $prefix -and $prefix -ne "EmptyNamePrefix") { $saName  = "${prefix}sa"  }
if (-not $sqlName -and $prefix -and $prefix -ne "EmptyNamePrefix") { $sqlName = "${prefix}-sql" }

# ---------------------------------------------------------------------------
# Load manifest
# ---------------------------------------------------------------------------

$manifestPath = Join-Path $PSScriptRoot "upgrade-manifest.json"
$manifest     = $null
if (Test-Path $manifestPath) {
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "RAVLs Optimization Engine Health Check" -ForegroundColor Cyan
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Check 1 — Resource existence
# ---------------------------------------------------------------------------

$rgOk     = $false
$rgDetail = ""
try {
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
    $rgOk     = $true
    $rgDetail = "Resource group: $ResourceGroupName ($($rg.Location))"

    # Check Storage Account
    $saFound  = $false
    $aaFound  = $false
    $sqlFound = $false
    $lawFound = $false

    $resources = Get-AzResource -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue

    $saList   = $resources | Where-Object { $_.ResourceType -eq "Microsoft.Storage/storageAccounts" }
    $aaList   = $resources | Where-Object { $_.ResourceType -eq "Microsoft.Automation/automationAccounts" }
    $sqlList  = $resources | Where-Object { $_.ResourceType -eq "Microsoft.Sql/servers" }
    $lawList  = $resources | Where-Object { $_.ResourceType -eq "Microsoft.OperationalInsights/workspaces" }

    # Resolve names from discovered resources if not in config
    if (-not $aaName  -and $aaList)  { $aaName  = $aaList[0].Name  }
    if (-not $saName  -and $saList)  { $saName  = $saList[0].Name  }
    if (-not $sqlName -and $sqlList) { $sqlName = $sqlList[0].Name }
    if (-not $lawName -and $lawList) { $lawName = $lawList[0].Name }

    $saFound  = $saList.Count  -gt 0
    $aaFound  = $aaList.Count  -gt 0
    $sqlFound = $sqlList.Count -gt 0
    $lawFound = $lawList.Count -gt 0

    $rgOk = $saFound -and $aaFound -and $sqlFound -and $lawFound
    $missing = @()
    if (-not $saFound)  { $missing += "Storage Account" }
    if (-not $aaFound)  { $missing += "Automation Account" }
    if (-not $sqlFound) { $missing += "SQL Server" }
    if (-not $lawFound) { $missing += "Log Analytics Workspace" }

    $rgDetail = if ($rgOk) {
        "Storage: $saName | Automation: $aaName | SQL: $sqlName | LAW: $lawName"
    } else {
        "Missing: $($missing -join ', ')"
    }
} catch {
    $rgDetail = "Resource group '$ResourceGroupName' not found or inaccessible: $($_.Exception.Message)"
}

Write-Check -Name "Resource group: $ResourceGroupName" `
            -Passed $rgOk `
            -Detail $rgDetail `
            -Fix    "Re-run Install-RAVLOptEngine.ps1 to deploy missing resources"

# ---------------------------------------------------------------------------
# Check 2 — Runbook count
# ---------------------------------------------------------------------------

$rbOk     = $false
$rbDetail = ""
$expectedCount = 0
$actualCount   = 0

if ($manifest) {
    foreach ($section in @("baseIngest", "dataCollection", "recommendations", "remediations", "orchestration")) {
        $entries = $manifest.$section
        if ($entries) { $expectedCount += $entries.Count }
    }
}

if ($aaName -and $rgOk) {
    try {
        $runbooks    = Get-AzAutomationRunbook -ResourceGroupName $ResourceGroupName -AutomationAccountName $aaName -ErrorAction Stop
        $actualCount = $runbooks.Count
        if ($expectedCount -gt 0) {
            $rbOk     = ($actualCount -ge $expectedCount)
            $rbDetail = "Found $actualCount runbooks (expected $expectedCount from manifest)"
        } else {
            $rbOk     = ($actualCount -gt 0)
            $rbDetail = "Found $actualCount runbooks (manifest not available for comparison)"
        }
    } catch {
        $rbDetail = "Could not retrieve runbooks: $($_.Exception.Message)"
    }
} else {
    $rbDetail = "Automation account not found — skipped"
}

Write-Check -Name "Automation account: $aaName ($actualCount runbooks)" `
            -Passed $rbOk `
            -Detail $rbDetail `
            -Fix    "Re-run Install-RAVLOptEngine.ps1 to upload missing runbooks"

# ---------------------------------------------------------------------------
# Check 3 — Core automation variables
# ---------------------------------------------------------------------------

$varsOk     = $false
$varsDetail = ""
$coreVars   = @(
    "AzureOptimization_StorageSink",
    "AzureOptimization_LogAnalyticsWorkspaceId",
    "AzureOptimization_SQLServerHostname"
)
$missingVars = @()

if ($aaName -and $rgOk) {
    try {
        foreach ($varName in $coreVars) {
            $v = Get-AzAutomationVariable -ResourceGroupName $ResourceGroupName `
                     -AutomationAccountName $aaName -Name $varName -ErrorAction SilentlyContinue
            if (-not $v) { $missingVars += $varName }
        }
        $varsOk     = ($missingVars.Count -eq 0)
        $varsDetail = if ($varsOk) {
            "All 3 core variables present"
        } else {
            "Missing: $($missingVars -join ', ')"
        }
    } catch {
        $varsDetail = "Could not retrieve variables: $($_.Exception.Message)"
    }
} else {
    $varsDetail = "Automation account not found — skipped"
}

Write-Check -Name "Core automation variables" `
            -Passed $varsOk `
            -Detail $varsDetail `
            -Fix    "Re-run Install-RAVLOptEngine.ps1 to recreate missing variables"

# ---------------------------------------------------------------------------
# Check 4 — Storage containers
# ---------------------------------------------------------------------------

$containersOk     = $false
$containersDetail = ""
$missingContainers = @()

# Collect required containers from manifest (non-AWS/GCP)
$requiredContainers = @()
if ($manifest) {
    foreach ($section in @("baseIngest", "dataCollection", "recommendations", "remediations", "orchestration")) {
        $entries = $manifest.$section
        if ($entries) {
            foreach ($entry in $entries) {
                if ($entry.container -and
                    $entry.container -notmatch "^aws" -and
                    $entry.container -notmatch "^gcp" -and
                    $entry.container -notin $requiredContainers) {
                    $requiredContainers += $entry.container
                }
            }
        }
    }
}

if ($saName -and $rgOk) {
    try {
        $storageCtx = (Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $saName -ErrorAction Stop).Context
        $existingContainers = (Get-AzStorageContainer -Context $storageCtx -ErrorAction SilentlyContinue).Name

        foreach ($c in $requiredContainers) {
            if ($c -notin $existingContainers) { $missingContainers += $c }
        }

        $containersOk     = ($missingContainers.Count -eq 0)
        $containersDetail = if ($containersOk) {
            "$($requiredContainers.Count) required containers present"
        } else {
            "Missing $($missingContainers.Count) containers: $($missingContainers[0..2] -join ', ')$(if ($missingContainers.Count -gt 3) { '...' })"
        }
    } catch {
        $containersDetail = "Could not check storage containers: $($_.Exception.Message)"
    }
} else {
    $containersDetail = "Storage account not found — skipped"
}

Write-Check -Name "Storage containers" `
            -Passed $containersOk `
            -Detail $containersDetail `
            -Fix    "Re-run Install-RAVLOptEngine.ps1 to create missing containers"

# ---------------------------------------------------------------------------
# Check 5 — SQL connectivity
# ---------------------------------------------------------------------------

$sqlOk     = $false
$sqlDetail = ""

if ($sqlName -and $rgOk) {
    try {
        $sqlServer = Get-AzSqlServer -ResourceGroupName $ResourceGroupName -ServerName $sqlName -ErrorAction Stop
        $sqlFqdn   = $sqlServer.FullyQualifiedDomainName

        # Get token — try -AsSecureString first (newer Az.Accounts), fall back to plain
        $token = $null
        try {
            $tokenResult = Get-AzAccessToken -ResourceUrl "https://database.windows.net/" -AsSecureString -ErrorAction Stop
            $bstr  = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($tokenResult.Token)
            $token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        } catch {
            $tokenResult = Get-AzAccessToken -ResourceUrl "https://database.windows.net/" -ErrorAction Stop
            $token = $tokenResult.Token
        }

        # Find the first database (not master)
        $databases = Get-AzSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $sqlName -ErrorAction SilentlyContinue |
                     Where-Object { $_.DatabaseName -ne "master" }
        $dbName = if ($databases) { $databases[0].DatabaseName } else { "master" }

        $connStr = "Server=tcp:$sqlFqdn,1433;Database=$dbName;Encrypt=True;TrustServerCertificate=False;Connection Timeout=15;"
        $conn    = New-Object System.Data.SqlClient.SqlConnection($connStr)
        $conn.AccessToken = $token
        $conn.Open()

        $cmd = $conn.CreateCommand()
        $cmd.CommandText    = "SELECT 1 AS TestResult"
        $cmd.CommandTimeout = 10
        $result = $cmd.ExecuteScalar()
        $conn.Close()

        $sqlOk     = ($result -eq 1)
        $sqlDetail = "Connected to $sqlFqdn ($dbName) — query succeeded"
    } catch {
        $sqlDetail = "SQL connectivity failed: $($_.Exception.Message)"
    }
} else {
    $sqlDetail = "SQL server not found — skipped"
}

Write-Check -Name "SQL connectivity" `
            -Passed $sqlOk `
            -Detail $sqlDetail `
            -Fix    "Check firewall rules, Entra admin config, and network access for $sqlName"

# ---------------------------------------------------------------------------
# Check 6 — Schedules
# ---------------------------------------------------------------------------

$schedulesOk     = $false
$schedulesDetail = ""

if ($aaName -and $rgOk) {
    try {
        $schedules = Get-AzAutomationSchedule -ResourceGroupName $ResourceGroupName `
                         -AutomationAccountName $aaName -ErrorAction Stop
        $enabled   = ($schedules | Where-Object { $_.IsEnabled }).Count
        $disabled  = ($schedules | Where-Object { -not $_.IsEnabled }).Count
        $total     = $schedules.Count

        $schedulesOk     = ($total -gt 0)
        $schedulesDetail = "$total schedules — $enabled enabled, $disabled disabled"
    } catch {
        $schedulesDetail = "Could not retrieve schedules: $($_.Exception.Message)"
    }
} else {
    $schedulesDetail = "Automation account not found — skipped"
}

Write-Check -Name "Automation schedules" `
            -Passed $schedulesOk `
            -Detail $schedulesDetail `
            -Fix    "Re-run Install-RAVLOptEngine.ps1 or Reset-AutomationSchedules.ps1"

# ---------------------------------------------------------------------------
# Checks 7 & 8 — Live export test (skip if -Quick)
# ---------------------------------------------------------------------------

if ($Quick) {
    Write-Host ""
    Write-Host "  [SKIP] Live export test (-Quick flag set)" -ForegroundColor DarkGray
    Write-Host "  [SKIP] Blob output validation (-Quick flag set)" -ForegroundColor DarkGray
} else {
    # Check 7 — Trigger test export
    $exportOk     = $false
    $exportDetail = ""
    $exportJobId  = $null

    if ($aaName -and $rgOk) {
        $testRunbook = "Export-ARGResourceContainersPropertiesToBlobStorage"
        try {
            $rb = Get-AzAutomationRunbook -ResourceGroupName $ResourceGroupName `
                      -AutomationAccountName $aaName -Name $testRunbook -ErrorAction SilentlyContinue
            if ($rb) {
                $job = Start-AzAutomationRunbook -ResourceGroupName $ResourceGroupName `
                           -AutomationAccountName $aaName -Name $testRunbook -ErrorAction Stop
                $exportJobId = $job.JobId
                Write-Host "       Job started: $exportJobId — waiting up to 5 minutes..." -ForegroundColor DarkGray

                $deadline  = (Get-Date).AddMinutes(5)
                $finalStatus = $null
                while ((Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 15
                    $jobStatus = Get-AzAutomationJob -ResourceGroupName $ResourceGroupName `
                                     -AutomationAccountName $aaName -Id $exportJobId -ErrorAction SilentlyContinue
                    if ($jobStatus.Status -in @("Completed", "Failed", "Stopped", "Suspended")) {
                        $finalStatus = $jobStatus.Status
                        break
                    }
                }

                $exportOk     = ($finalStatus -eq "Completed")
                $exportDetail = if ($finalStatus) { "Job $exportJobId finished with status: $finalStatus" } else { "Job timed out after 5 minutes" }
            } else {
                $exportDetail = "Runbook '$testRunbook' not found — skipped"
            }
        } catch {
            $exportDetail = "Could not start test export: $($_.Exception.Message)"
        }
    } else {
        $exportDetail = "Automation account not found — skipped"
    }

    Write-Check -Name "Test export (Export-ARGResourceContainersPropertiesToBlobStorage)" `
                -Passed $exportOk `
                -Detail $exportDetail `
                -Fix    "Check runbook output and Automation Account logs for errors"

    # Check 8 — Verify blob output
    $blobOk     = $false
    $blobDetail = ""
    $blobContainer = "argrescontainersexports"

    if ($exportOk -and $saName -and $rgOk) {
        try {
            $storageCtx = (Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $saName -ErrorAction Stop).Context
            $cutoff     = (Get-Date).AddMinutes(-10)
            $blobs      = Get-AzStorageBlob -Container $blobContainer -Context $storageCtx -ErrorAction SilentlyContinue |
                          Where-Object { $_.LastModified -gt $cutoff -and $_.Name -like "*.csv" }

            $blobOk     = ($blobs.Count -gt 0)
            $blobDetail = if ($blobOk) {
                "Found $($blobs.Count) CSV blob(s) in '$blobContainer' (last 10 min)"
            } else {
                "No recent CSV blobs found in '$blobContainer'"
            }
        } catch {
            $blobDetail = "Could not check blob output: $($_.Exception.Message)"
        }
    } elseif (-not $exportOk) {
        $blobDetail = "Export job did not complete — skipped"
    } else {
        $blobDetail = "Storage account not found — skipped"
    }

    Write-Check -Name "Blob output in '$blobContainer'" `
                -Passed $blobOk `
                -Detail $blobDetail `
                -Fix    "Check runbook logs and storage account firewall settings"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

$total  = $script:CheckResults.Count
$passed = ($script:CheckResults | Where-Object { $_.Passed }).Count
$allOk  = ($passed -eq $total)

Write-Host ""
Write-Host "=======================================" -ForegroundColor Cyan

if ($allOk) {
    Write-Host "Result: $passed/$total passed. Engine is healthy." -ForegroundColor Green
} else {
    $failed = $total - $passed
    Write-Host "Result: $passed/$total passed. $failed check(s) failed." -ForegroundColor Red
    Write-Host ""
    Write-Host "Failed checks:" -ForegroundColor Yellow
    foreach ($r in $script:CheckResults | Where-Object { -not $_.Passed }) {
        Write-Host "  - $($r.Name)" -ForegroundColor Yellow
        if ($r.Fix) { Write-Host "    FIX: $($r.Fix)" -ForegroundColor DarkGray }
    }
}

Write-Host ""

exit $(if ($allOk) { 0 } else { 1 })
