<#
.SYNOPSIS
Guided installer for the RAVL Optimization Engine.

.DESCRIPTION
This script wraps Deploy-AzureOptimizationEngine.ps1 with a friendly interactive wizard,
pre-flight checks, and deployment orchestration. It guides the user through all required
settings, validates prerequisites, and invokes the deploy script with a generated config.

.EXAMPLE
.\Install-RAVLOptEngine.ps1

Launches the interactive wizard and installs or upgrades the RAVL Optimization Engine.
#>

#Requires -Version 7.0

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# PART 1 — Pre-Flight Checks
# ---------------------------------------------------------------------------

$script:CheckResults = [System.Collections.Generic.List[hashtable]]::new()

function Write-Check {
    param (
        [string]  $Name,
        [bool]    $Passed,
        [string]  $Detail   = "",
        [string]  $Fix      = ""
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

function Test-Prerequisites {
    [CmdletBinding()]
    param (
        [hashtable] $Config
    )

    $script:CheckResults.Clear()

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Pre-Flight Checks" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    # 1. PowerShell version
    $psVersion = $PSVersionTable.PSVersion
    $psOk = ($psVersion.Major -ge 7)
    Write-Check -Name "PowerShell version (7.x+ required)" `
                -Passed $psOk `
                -Detail "Detected: $($psVersion.ToString())" `
                -Fix    "Install PowerShell 7+ from https://aka.ms/powershell"

    # 2. Az modules
    $requiredModules = @(
        "Az.Accounts", "Az.Resources", "Az.Automation",
        "Az.Sql", "Az.Storage", "Az.OperationalInsights"
    )
    $missingModules = @()
    foreach ($mod in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            $missingModules += $mod
        }
    }
    $modsOk = ($missingModules.Count -eq 0)
    $modsDetail = if ($modsOk) { "All required modules present" } else { "Missing: $($missingModules -join ', ')" }
    Write-Check -Name "Required Az PowerShell modules" `
                -Passed $modsOk `
                -Detail $modsDetail `
                -Fix    "Run: Install-Module Az -Scope CurrentUser -Force"

    # 3. Azure authentication
    $authOk = $false
    $authDetail = ""
    try {
        $ctx = Get-AzContext
        if ($ctx -and $ctx.Account) {
            $authOk = $true
            $authDetail = "Signed in as: $($ctx.Account.Id)"
        } else {
            $authDetail = "No active Azure context"
        }
    } catch {
        $authDetail = $_.Exception.Message
    }
    Write-Check -Name "Azure authentication" `
                -Passed $authOk `
                -Detail $authDetail `
                -Fix    "Run: Connect-AzAccount"

    # 4. Subscription access
    $subOk = $false
    $subDetail = ""
    if ($Config.SubscriptionId -and $authOk) {
        try {
            $sub = Get-AzSubscription -SubscriptionId $Config.SubscriptionId -ErrorAction Stop
            $subOk = ($null -ne $sub)
            $subDetail = if ($subOk) { "Subscription: $($sub.Name) ($($sub.Id))" } else { "Subscription not found" }
        } catch {
            $subDetail = "Could not access subscription $($Config.SubscriptionId): $($_.Exception.Message)"
        }
    } else {
        $subDetail = "SubscriptionId not yet configured — will be validated after wizard"
    }
    Write-Check -Name "Subscription access" `
                -Passed ($subOk -or -not $Config.SubscriptionId) `
                -Detail $subDetail `
                -Fix    "Ensure you have access to subscription $($Config.SubscriptionId) and are signed in with the correct account"

    # 5. Region availability (SQL)
    $regionOk = $false
    $regionDetail = ""
    if ($Config.TargetLocation -and $authOk) {
        try {
            $sqlCap = Get-AzSqlCapability -LocationName $Config.TargetLocation -ErrorAction Stop
            $regionOk = ($null -ne $sqlCap)
            $regionDetail = if ($regionOk) { "Azure SQL available in $($Config.TargetLocation)" } else { "Azure SQL not available in $($Config.TargetLocation)" }
        } catch {
            $regionDetail = "Could not check SQL capability for $($Config.TargetLocation): $($_.Exception.Message)"
        }
    } else {
        $regionDetail = "TargetLocation not yet configured — will be validated after wizard"
    }
    Write-Check -Name "Region availability (Azure SQL)" `
                -Passed ($regionOk -or -not $Config.TargetLocation) `
                -Detail $regionDetail `
                -Fix    "Choose a region where Azure SQL is available"

    # 6. Subscription role (Contributor or Owner)
    $roleOk = $false
    $roleDetail = ""
    if ($Config.SubscriptionId -and $authOk) {
        try {
            $scope = "/subscriptions/$($Config.SubscriptionId)"
            $ctx2 = Get-AzContext
            $assignments = Get-AzRoleAssignment -Scope $scope -SignInName $ctx2.Account.Id -ErrorAction SilentlyContinue
            $eligible = $assignments | Where-Object { $_.RoleDefinitionName -in @("Owner", "Contributor") }
            $roleOk = ($eligible.Count -gt 0)
            $roleDetail = if ($roleOk) {
                "Role: $($eligible[0].RoleDefinitionName)"
            } else {
                "Missing Contributor or Owner role on the subscription"
            }
        } catch {
            $roleDetail = "Could not check role assignments: $($_.Exception.Message)"
        }
    } else {
        $roleDetail = "SubscriptionId not yet configured"
    }
    Write-Check -Name "Subscription role (Contributor/Owner)" `
                -Passed ($roleOk -or -not $Config.SubscriptionId) `
                -Detail $roleDetail `
                -Fix    "Request Contributor or Owner role on subscription $($Config.SubscriptionId)"

    # 7. Name availability — Storage Account and SQL Server
    $nameOk = $true
    $nameDetail = ""
    if ($Config.SubscriptionId -and $Config.NamePrefix -and $authOk) {
        $prefix = $Config.NamePrefix

        # Derive resource names using same logic as Deploy script
        if ($prefix -eq "EmptyNamePrefix") {
            $saName  = $Config.StorageAccountName
            $sqlName = $Config.SqlServerName
        } else {
            $saName  = "${prefix}sa"
            $sqlName = "${prefix}-sql"
        }

        if ($saName) {
            try {
                $saAvail = Get-AzStorageAccountNameAvailability -Name $saName
                if (-not $saAvail.NameAvailable) {
                    $nameOk = $false
                    $nameDetail += "Storage '$saName' unavailable: $($saAvail.Message). "
                }
            } catch {
                $nameDetail += "Could not check storage name: $($_.Exception.Message). "
            }
        }

        if ($sqlName -and $Config.SubscriptionId) {
            try {
                $sqlUri  = "/subscriptions/$($Config.SubscriptionId)/providers/Microsoft.Sql/checkNameAvailability?api-version=2021-11-01"
                $sqlBody = "{`"name`": `"$sqlName`", `"type`": `"Microsoft.Sql/servers`"}"
                $sqlResp = (Invoke-AzRestMethod -Path $sqlUri -Method POST -Payload $sqlBody).Content | ConvertFrom-Json
                if (-not $sqlResp.available) {
                    $nameOk = $false
                    $nameDetail += "SQL Server '$sqlName' unavailable: $($sqlResp.message). "
                }
            } catch {
                $nameDetail += "Could not check SQL server name: $($_.Exception.Message). "
            }
        }

        if ($nameOk) { $nameDetail = "Storage '$saName' and SQL '$sqlName' are available" }
    } else {
        $nameDetail = "Name prefix not yet configured — will be validated after wizard"
    }
    Write-Check -Name "Resource name availability" `
                -Passed ($nameOk -or -not $Config.NamePrefix) `
                -Detail $nameDetail `
                -Fix    "Choose a different name prefix or resource names"

    # 8. Resource group — exists or can create
    $rgOk = $false
    $rgDetail = ""
    if ($Config.ResourceGroupName -and $Config.SubscriptionId -and $authOk) {
        try {
            $rg = Get-AzResourceGroup -Name $Config.ResourceGroupName -ErrorAction SilentlyContinue
            if ($rg) {
                $rgOk = $true
                $rgDetail = "Resource group '$($Config.ResourceGroupName)' already exists in $($rg.Location)"
            } else {
                # Check if user can create RGs by verifying subscription-level permissions
                $rgOk = $true  # Assume create is possible; ARM will validate
                $rgDetail = "Resource group '$($Config.ResourceGroupName)' will be created"
            }
        } catch {
            $rgDetail = "Could not check resource group: $($_.Exception.Message)"
        }
    } else {
        $rgDetail = "Resource group not yet configured"
    }
    Write-Check -Name "Resource group access" `
                -Passed ($rgOk -or -not $Config.ResourceGroupName) `
                -Detail $rgDetail `
                -Fix    "Ensure you have permission to create resource groups in the subscription"

    # 9. Template access (hosted/GitHub mode)
    $tplOk = $false
    $tplDetail = ""
    if ($Config.DeploymentSource -eq "GitHub") {
        $tplUrl = "https://raw.githubusercontent.com/Ravl-io/ravl-opt-engine/main/src/optimization-engine/azuredeploy.bicep"
        try {
            $resp = Invoke-WebRequest -Uri $tplUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            $tplOk = ($resp.StatusCode -eq 200)
            $tplDetail = "GitHub template reachable (HTTP $($resp.StatusCode))"
        } catch {
            $tplDetail = "Cannot reach GitHub template: $($_.Exception.Message)"
        }
    } else {
        # Local mode — check local files
        $localBicep       = Join-Path $PSScriptRoot "azuredeploy.bicep"
        $localNestedBicep = Join-Path $PSScriptRoot "azuredeploy-nested.bicep"
        $tplOk = (Test-Path $localBicep) -and (Test-Path $localNestedBicep)
        $tplDetail = if ($tplOk) { "Local template files found" } else { "Missing: azuredeploy.bicep and/or azuredeploy-nested.bicep" }
    }
    Write-Check -Name "Template accessibility" `
                -Passed $tplOk `
                -Detail $tplDetail `
                -Fix    "Ensure internet access (GitHub mode) or run from the directory containing azuredeploy.bicep (local mode)"

    Write-Host ""
}

function Show-PreflightSummary {
    [OutputType([bool])]
    param ()

    $total  = $script:CheckResults.Count
    $passed = ($script:CheckResults | Where-Object { $_.Passed }).Count
    $failed = $total - $passed

    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Pre-Flight Summary: $passed/$total passed" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    if ($failed -gt 0) {
        Write-Host "The following checks FAILED:" -ForegroundColor Red
        foreach ($r in $script:CheckResults | Where-Object { -not $_.Passed }) {
            Write-Host "  - $($r.Name)" -ForegroundColor Red
            if ($r.Fix) { Write-Host "    Fix: $($r.Fix)" -ForegroundColor Yellow }
        }
        Write-Host ""
        return $false
    }

    Write-Host "All checks passed. Proceeding with deployment." -ForegroundColor Green
    Write-Host ""
    return $true
}

# ---------------------------------------------------------------------------
# PART 2 — Interactive Wizard
# ---------------------------------------------------------------------------

$script:ConfigPath = Join-Path $PSScriptRoot "ravl-oe-config.json"

function Read-Selection {
    param (
        [string]   $Prompt,
        [string[]] $Options,
        [int]      $DefaultIndex = 0
    )

    Write-Host ""
    Write-Host $Prompt -ForegroundColor Cyan
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $marker = if ($i -eq $DefaultIndex) { "*" } else { " " }
        Write-Host "  [$i]$marker $($Options[$i])"
    }
    Write-Host ""

    do {
        $raw = Read-Host "  Enter number (default $DefaultIndex)"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $DefaultIndex }
        $parsed = 0
        $valid  = [int]::TryParse($raw.Trim(), [ref]$parsed) -and $parsed -ge 0 -and $parsed -lt $Options.Count
    } while (-not $valid)

    return $parsed
}

function Read-Value {
    param (
        [string] $Prompt,
        [string] $Default = "",
        [int]    $MaxLength = 0
    )

    $hint = if ($Default) { " [default: $Default]" } else { "" }
    do {
        $raw = Read-Host "$Prompt$hint"
        if ([string]::IsNullOrWhiteSpace($raw) -and $Default) { $raw = $Default }
        $tooLong = ($MaxLength -gt 0) -and ($raw.Length -gt $MaxLength)
        if ($tooLong) { Write-Host "  Value must be $MaxLength characters or fewer. Try again." -ForegroundColor Yellow }
    } while ($tooLong)

    return $raw.Trim()
}

function Read-YesNo {
    param (
        [string] $Prompt,
        [bool]   $Default = $true
    )

    $hint = if ($Default) { "[Y/n]" } else { "[y/N]" }
    do {
        $raw = Read-Host "$Prompt $hint"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        $raw = $raw.Trim().ToLower()
    } while ($raw -notin @("y", "n", "yes", "no"))

    return $raw -in @("y", "yes")
}

function Load-Config {
    [OutputType([hashtable])]
    param ()

    if (Test-Path $script:ConfigPath) {
        $json = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
        $ht   = @{}
        foreach ($prop in $json.PSObject.Properties) {
            $ht[$prop.Name] = $prop.Value
        }
        return $ht
    }
    return @{}
}

function Save-Config {
    param ([hashtable] $Config)

    $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $script:ConfigPath -Encoding UTF8
    Write-Host "  Configuration saved to $script:ConfigPath" -ForegroundColor DarkGray
}

function Start-Wizard {
    [OutputType([hashtable])]
    param ()

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  RAVL Optimization Engine — Installer" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # Detect existing config and deployment state
    $existingConfig  = Load-Config
    $lastStatePath   = Join-Path $PSScriptRoot "last-deployment-state.json"
    $isUpgrade       = (Test-Path $script:ConfigPath) -or (Test-Path $lastStatePath)

    $config = @{
        EnableDefaultTelemetry          = $true
        IgnoreNamingAvailabilityErrors  = $false
    }

    # Merge existing config as defaults when upgrading
    if ($isUpgrade -and $existingConfig.Count -gt 0) {
        foreach ($k in $existingConfig.Keys) { $config[$k] = $existingConfig[$k] }
    }

    # -- Q1: Deployment mode --
    $modeOptions  = @("New installation", "Upgrade existing deployment")
    $modeDefault  = if ($isUpgrade) { 1 } else { 0 }
    $modeIdx      = Read-Selection -Prompt "1/13  Deployment mode" -Options $modeOptions -DefaultIndex $modeDefault
    $config["DeploymentMode"] = if ($modeIdx -eq 0) { "new" } else { "upgrade" }

    if ($modeIdx -eq 1 -and $isUpgrade) {
        Write-Host "  Loading existing configuration as defaults..." -ForegroundColor DarkGray
    }

    # -- Q2: Deployment source --
    $localBicepExists = (Test-Path (Join-Path $PSScriptRoot "azuredeploy.bicep")) -and
                        (Test-Path (Join-Path $PSScriptRoot "azuredeploy-nested.bicep"))
    $srcOptions  = @("Local files (this directory)", "GitHub (latest published release)")
    $srcDefault  = if ($localBicepExists) { 0 } else { 1 }
    $srcIdx      = Read-Selection -Prompt "2/13  Deployment source" -Options $srcOptions -DefaultIndex $srcDefault
    $config["DeploymentSource"] = if ($srcIdx -eq 0) { "Local" } else { "GitHub" }

    # -- Q3: Subscription --
    Write-Host ""
    Write-Host "3/13  Azure Subscription" -ForegroundColor Cyan
    Write-Host "  Fetching subscriptions..." -ForegroundColor DarkGray
    try {
        $subs = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" -and $_.SubscriptionPolicies.QuotaId -notlike "AAD*" }
    } catch {
        $subs = @()
        Write-Host "  Warning: Could not retrieve subscriptions — $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if ($subs.Count -gt 0) {
        $subNames    = $subs | ForEach-Object { "$($_.Name) ($($_.Id))" }
        $subDefault  = 0
        if ($config["SubscriptionId"]) {
            $match = [Array]::FindIndex($subs, [Predicate[object]]{ $args[0].Id -eq $config["SubscriptionId"] })
            if ($match -ge 0) { $subDefault = $match }
        }
        $subIdx = Read-Selection -Prompt "  Select target subscription" -Options $subNames -DefaultIndex $subDefault
        $config["SubscriptionId"] = $subs[$subIdx].Id
    } else {
        $config["SubscriptionId"] = Read-Value -Prompt "  Enter subscription ID" -Default ($config["SubscriptionId"] ?? "")
    }

    # -- Q4: Region --
    $commonRegions = @("eastus", "eastus2", "westus2", "centralus", "canadacentral", "westeurope", "northeurope")
    $regionDefault = 0
    if ($config["TargetLocation"]) {
        $ri = [Array]::IndexOf($commonRegions, $config["TargetLocation"])
        if ($ri -ge 0) { $regionDefault = $ri }
    }
    $regionIdx = Read-Selection -Prompt "4/13  Target Azure region" -Options $commonRegions -DefaultIndex $regionDefault
    $config["TargetLocation"] = $commonRegions[$regionIdx]

    # -- Q5: Resource group name --
    $rgDefault = $config["ResourceGroupName"] ?? "ravl-optimization-engine"
    $config["ResourceGroupName"] = Read-Value -Prompt "5/13  Resource group name" -Default $rgDefault

    # -- Q6: Naming prefix --
    Write-Host ""
    Write-Host "6/13  Resource naming prefix (max 21 chars)" -ForegroundColor Cyan
    $prefixDefault = $config["NamePrefix"] ?? "ravlopt"
    if ($prefixDefault -eq "EmptyNamePrefix") { $prefixDefault = "ravlopt" }
    do {
        $prefix = Read-Value -Prompt "  Enter prefix (or press ENTER for default)" -Default $prefixDefault -MaxLength 21
    } while ($prefix.Length -gt 21)
    $config["NamePrefix"] = $prefix

    Write-Host "  Resource name preview:" -ForegroundColor DarkGray
    Write-Host "    Storage Account : ${prefix}sa"    -ForegroundColor DarkGray
    Write-Host "    Automation Acct : ${prefix}-auto" -ForegroundColor DarkGray
    Write-Host "    SQL Server      : ${prefix}-sql"  -ForegroundColor DarkGray
    Write-Host "    Log Analytics   : ${prefix}-la"   -ForegroundColor DarkGray

    # -- Q7: Log Analytics reuse --
    $wkspReuseDefault = ($config["WorkspaceReuse"] -eq "y")
    $reuseWs = Read-YesNo -Prompt "7/13  Reuse an existing Log Analytics workspace?" -Default $wkspReuseDefault
    $config["WorkspaceReuse"] = if ($reuseWs) { "y" } else { "n" }

    if ($reuseWs) {
        $config["WorkspaceName"]              = Read-Value -Prompt "  Existing workspace name" -Default ($config["WorkspaceName"] ?? "")
        $config["WorkspaceResourceGroupName"] = Read-Value -Prompt "  Workspace resource group" -Default ($config["WorkspaceResourceGroupName"] ?? $config["ResourceGroupName"])
    }

    # -- Q8: SQL Admin principal --
    Write-Host ""
    Write-Host "8/13  SQL Admin principal" -ForegroundColor Cyan
    $principalTypes = @("User (current signed-in user)", "Group (Azure AD group)", "ServicePrincipal")
    $ptDefault = 0
    if ($config["SqlAdminPrincipalType"] -eq "Group")             { $ptDefault = 1 }
    elseif ($config["SqlAdminPrincipalType"] -eq "ServicePrincipal") { $ptDefault = 2 }
    $ptIdx = Read-Selection -Prompt "  SQL Admin type" -Options $principalTypes -DefaultIndex $ptDefault

    switch ($ptIdx) {
        0 {
            $config["SqlAdminPrincipalType"] = "User"
            try {
                $me = Get-AzADUser -SignedIn -Select UserPrincipalName, Id
                if ($me) {
                    $config["SqlAdminPrincipalName"]     = $me.UserPrincipalName
                    $config["SqlAdminPrincipalObjectId"] = $me.Id
                    Write-Host "  Auto-detected: $($me.UserPrincipalName)" -ForegroundColor DarkGray
                }
            } catch {
                Write-Host "  Could not auto-detect signed-in user. Enter manually:" -ForegroundColor Yellow
                $config["SqlAdminPrincipalName"]     = Read-Value -Prompt "  UPN" -Default ($config["SqlAdminPrincipalName"] ?? "")
                $config["SqlAdminPrincipalObjectId"] = Read-Value -Prompt "  Object ID" -Default ($config["SqlAdminPrincipalObjectId"] ?? "")
            }
        }
        1 {
            $config["SqlAdminPrincipalType"]     = "Group"
            $config["SqlAdminPrincipalName"]     = Read-Value -Prompt "  Group display name" -Default ($config["SqlAdminPrincipalName"] ?? "")
            $config["SqlAdminPrincipalObjectId"] = Read-Value -Prompt "  Group object ID"    -Default ($config["SqlAdminPrincipalObjectId"] ?? "")
        }
        2 {
            $config["SqlAdminPrincipalType"]     = "ServicePrincipal"
            $config["SqlAdminPrincipalName"]     = Read-Value -Prompt "  Service principal name" -Default ($config["SqlAdminPrincipalName"] ?? "")
            $config["SqlAdminPrincipalObjectId"] = Read-Value -Prompt "  Service principal object ID" -Default ($config["SqlAdminPrincipalObjectId"] ?? "")
        }
    }

    # -- Q9: Azure environment --
    $envOptions  = @("AzureCloud (default global)", "AzureChinaCloud")
    $envDefault  = if ($config["AzureEnvironment"] -eq "AzureChinaCloud") { 1 } else { 0 }
    $envIdx      = Read-Selection -Prompt "9/13  Azure environment" -Options $envOptions -DefaultIndex $envDefault
    $config["AzureEnvironment"] = if ($envIdx -eq 0) { "AzureCloud" } else { "AzureChinaCloud" }

    # -- Q10: Resource tags --
    Write-Host ""
    Write-Host "10/13  Resource tags (optional)" -ForegroundColor Cyan
    Write-Host "  Enter key=value pairs one per line. Press ENTER on empty line to finish." -ForegroundColor DarkGray
    $tags = @{}
    if ($config["ResourceTags"] -is [hashtable]) { $tags = $config["ResourceTags"] }
    if ($tags.Count -gt 0) {
        Write-Host "  Current tags:" -ForegroundColor DarkGray
        foreach ($k in $tags.Keys) { Write-Host "    $k = $($tags[$k])" -ForegroundColor DarkGray }
        $clearTags = Read-YesNo -Prompt "  Clear existing tags and re-enter?" -Default $false
        if ($clearTags) { $tags = @{} }
    }
    while ($true) {
        $pair = Read-Host "  tag (key=value)"
        if ([string]::IsNullOrWhiteSpace($pair)) { break }
        $parts = $pair.Split("=", 2)
        if ($parts.Count -eq 2) {
            $tags[$parts[0].Trim()] = $parts[1].Trim()
        } else {
            Write-Host "  Invalid format. Use key=value." -ForegroundColor Yellow
        }
    }
    $config["ResourceTags"] = $tags

    # -- Q11: Workbooks --
    $wbDefault = ($config["DeployWorkbooks"] -ne "n")
    $deployWb  = Read-YesNo -Prompt "11/13  Deploy Azure Workbooks?" -Default $wbDefault
    $config["DeployWorkbooks"] = if ($deployWb) { "y" } else { "n" }

    # -- Q12: Benefits / Cost Management dependencies --
    $benDefault = ($config["DeployBenefitsUsageDependencies"] -eq "y")
    $deployBen  = Read-YesNo -Prompt "12/13  Deploy Benefits/Cost Management dependencies?" -Default $benDefault
    $config["DeployBenefitsUsageDependencies"] = if ($deployBen) { "y" } else { "n" }

    if ($deployBen) {
        $custTypes = @("EA (Enterprise Agreement)", "MCA (Microsoft Customer Agreement)", "PAYG (Pay-As-You-Go)")
        $ctDefault = 0
        if ($config["CustomerType"] -eq "MCA")  { $ctDefault = 1 }
        elseif ($config["CustomerType"] -eq "PAYG") { $ctDefault = 2 }
        $ctIdx = Read-Selection -Prompt "  Customer/agreement type" -Options $custTypes -DefaultIndex $ctDefault
        $config["CustomerType"] = switch ($ctIdx) { 0 { "EA" } 1 { "MCA" } 2 { "PAYG" } }

        $config["BillingAccountId"] = Read-Value -Prompt "  Billing account ID" -Default ($config["BillingAccountId"] ?? "")
        $config["CurrencyCode"]     = Read-Value -Prompt "  Currency code (e.g. USD)" -Default ($config["CurrencyCode"] ?? "USD")

        if ($config["CustomerType"] -eq "MCA") {
            $config["BillingProfileId"] = Read-Value -Prompt "  MCA Billing profile ID" -Default ($config["BillingProfileId"] ?? "")
        }
    }

    # -- Q13: Confirmation / summary --
    Write-Host ""
    Write-Host "13/13  Deployment summary" -ForegroundColor Cyan
    Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
    $summaryFields = @(
        @{ Label = "Mode";               Value = $config["DeploymentMode"] }
        @{ Label = "Source";             Value = $config["DeploymentSource"] }
        @{ Label = "Subscription";       Value = $config["SubscriptionId"] }
        @{ Label = "Region";             Value = $config["TargetLocation"] }
        @{ Label = "Resource group";     Value = $config["ResourceGroupName"] }
        @{ Label = "Name prefix";        Value = $config["NamePrefix"] }
        @{ Label = "Workspace reuse";    Value = $config["WorkspaceReuse"] }
        @{ Label = "Workbooks";          Value = $config["DeployWorkbooks"] }
        @{ Label = "Benefits deps";      Value = $config["DeployBenefitsUsageDependencies"] }
        @{ Label = "Azure environment";  Value = $config["AzureEnvironment"] }
        @{ Label = "SQL admin type";     Value = $config["SqlAdminPrincipalType"] }
        @{ Label = "SQL admin name";     Value = $config["SqlAdminPrincipalName"] }
    )
    foreach ($f in $summaryFields) {
        Write-Host ("  {0,-22} {1}" -f "$($f.Label):", $f.Value)
    }
    if ($config["ResourceTags"].Count -gt 0) {
        Write-Host "  Tags:"
        foreach ($k in $config["ResourceTags"].Keys) {
            Write-Host "    $k = $($config["ResourceTags"][$k])"
        }
    }
    Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
    Write-Host ""

    Save-Config -Config $config

    $proceed = Read-YesNo -Prompt "  Proceed with deployment?" -Default $true
    if (-not $proceed) {
        Write-Host "  Deployment cancelled. Configuration saved to $script:ConfigPath" -ForegroundColor Yellow
        exit 0
    }

    return $config
}

# ---------------------------------------------------------------------------
# PART 3 — Deployment Orchestration
# ---------------------------------------------------------------------------

function Install-RAVLOptEngine {
    [CmdletBinding()]
    param ()

    # ---- Step 1: Run wizard ----
    $config = Start-Wizard

    # ---- Step 2: Pre-flight checks ----
    Test-Prerequisites -Config $config
    $preflightPassed = Show-PreflightSummary

    if (-not $preflightPassed) {
        $force = Read-YesNo -Prompt "Pre-flight checks failed. Continue anyway (not recommended)?" -Default $false
        if (-not $force) {
            Write-Host "Deployment aborted. Fix the issues above and re-run the installer." -ForegroundColor Red
            exit 1
        }
        Write-Host "Continuing despite failed checks..." -ForegroundColor Yellow
    }

    # ---- Step 3: Save config (already saved by wizard, refresh) ----
    Save-Config -Config $config

    # ---- Step 4: Determine template URI ----
    $templateUri           = $null
    $stagingServer         = $null
    $stagingContainer      = $null
    $stagingStorageAccount = $null

    try {
        if ($config["DeploymentSource"] -eq "GitHub") {
            $templateUri = "https://raw.githubusercontent.com/Ravl-io/ravl-opt-engine/main/src/optimization-engine/azuredeploy.bicep"
            Write-Host "Using GitHub template: $templateUri" -ForegroundColor DarkGray
        } else {
            # Local mode — serve templates via blob storage staging container or local HTTP listener
            $prefix         = $config["NamePrefix"]
            $saName         = if ($prefix -eq "EmptyNamePrefix") { $config["StorageAccountName"] } else { "${prefix}sa" }
            $subscriptionId = $config["SubscriptionId"]
            $rgName         = $config["ResourceGroupName"]

            # Try to upload to blob storage staging container
            $stagingContainerName = "installer-staging"

            try {
                Write-Host "Attempting to stage templates in Azure Blob Storage..." -ForegroundColor DarkGray

                # Ensure the subscription context is set
                if ((Get-AzContext).Subscription.Id -ne $subscriptionId) {
                    Select-AzSubscription -SubscriptionId $subscriptionId | Out-Null
                }

                $sa = Get-AzStorageAccount -ResourceGroupName $rgName -Name $saName -ErrorAction SilentlyContinue
                if (-not $sa) {
                    # Storage account doesn't exist yet — fall back to local HTTP listener
                    throw "Storage account '$saName' does not exist yet; using local HTTP listener instead."
                }

                $stagingStorageAccount = $sa
                $ctx2 = $sa.Context

                # Create staging container if needed
                $container = Get-AzStorageContainer -Name $stagingContainerName -Context $ctx2 -ErrorAction SilentlyContinue
                if (-not $container) {
                    New-AzStorageContainer -Name $stagingContainerName -Context $ctx2 -Permission Off | Out-Null
                }
                $stagingContainer = $stagingContainerName

                # Upload template files
                $templateFiles = @("azuredeploy.bicep", "azuredeploy-nested.bicep")
                foreach ($tf in $templateFiles) {
                    $localPath = Join-Path $PSScriptRoot $tf
                    if (Test-Path $localPath) {
                        Set-AzStorageBlobContent -File $localPath -Container $stagingContainerName -Blob $tf `
                            -Context $ctx2 -Force | Out-Null
                        Write-Host "  Uploaded: $tf" -ForegroundColor DarkGray
                    }
                }

                # Generate SAS token (2 hours)
                $sasExpiry = (Get-Date).ToUniversalTime().AddHours(2)
                $sasToken  = New-AzStorageContainerSASToken -Name $stagingContainerName -Context $ctx2 `
                                 -Permission r -ExpiryTime $sasExpiry -Protocol HttpsOnly

                $templateUri = "$($sa.PrimaryEndpoints.Blob)$stagingContainerName/azuredeploy.bicep$sasToken"
                Write-Host "Templates staged in blob storage." -ForegroundColor DarkGray

            } catch {
                Write-Host "Blob staging not available: $($_.Exception.Message)" -ForegroundColor DarkGray
                Write-Host "Starting local HTTP listener for template serving..." -ForegroundColor DarkGray

                # Start PowerShell HttpListener on localhost with port increment
                $port            = 8765
                $maxPortAttempts = 10
                $listener        = $null

                for ($attempt = 0; $attempt -lt $maxPortAttempts; $attempt++) {
                    try {
                        $l = [System.Net.HttpListener]::new()
                        $l.Prefixes.Add("http://localhost:$port/")
                        $l.Start()
                        $listener = $l
                        Write-Host "  Local HTTP server listening on port $port" -ForegroundColor DarkGray
                        break
                    } catch {
                        Write-Host "  Port $port in use, trying $($port + 1)..." -ForegroundColor DarkGray
                        $port++
                    }
                }

                if (-not $listener) {
                    throw "Could not start local HTTP listener on any port from 8765 to $($port - 1). Free a port and retry."
                }

                $stagingServer = $listener
                $templateUri   = "http://localhost:$port/azuredeploy.bicep"

                # Serve template requests in a background runspace
                $runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 1)
                $runspacePool.Open()
                $ps = [System.Management.Automation.PowerShell]::Create()
                $ps.RunspacePool = $runspacePool
                [void]$ps.AddScript({
                    param ($httpListener, $root)
                    while ($httpListener.IsListening) {
                        try {
                            $ctx3     = $httpListener.GetContext()
                            $reqPath  = $ctx3.Request.Url.LocalPath.TrimStart("/")
                            $filePath = Join-Path $root $reqPath
                            if (Test-Path $filePath) {
                                $bytes = [System.IO.File]::ReadAllBytes($filePath)
                                $ctx3.Response.ContentLength64 = $bytes.Length
                                $ctx3.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                            } else {
                                $ctx3.Response.StatusCode = 404
                            }
                            $ctx3.Response.OutputStream.Close()
                        } catch { }
                    }
                }).AddArgument($listener).AddArgument($PSScriptRoot)
                [void]$ps.BeginInvoke()
            }
        }

        # ---- Step 5: Build and invoke Deploy-AzureOptimizationEngine.ps1 ----
        $deployScript = Join-Path $PSScriptRoot "Deploy-AzureOptimizationEngine.ps1"
        if (-not (Test-Path $deployScript)) {
            throw "Deploy-AzureOptimizationEngine.ps1 not found at: $deployScript"
        }

        # Build the silent config JSON compatible with Deploy script validation
        $silentConfig = @{
            SubscriptionId                  = $config["SubscriptionId"]
            NamePrefix                      = $config["NamePrefix"]
            ResourceGroupName               = $config["ResourceGroupName"]
            TargetLocation                  = $config["TargetLocation"]
            WorkspaceReuse                  = $config["WorkspaceReuse"]
            DeployWorkbooks                 = $config["DeployWorkbooks"]
            DeployBenefitsUsageDependencies = $config["DeployBenefitsUsageDependencies"]
        }

        # Optional fields for EmptyNamePrefix
        if ($config["NamePrefix"] -eq "EmptyNamePrefix") {
            $silentConfig["StorageAccountName"]    = $config["StorageAccountName"]
            $silentConfig["AutomationAccountName"] = $config["AutomationAccountName"]
            $silentConfig["SqlServerName"]         = $config["SqlServerName"]
            $silentConfig["SqlDatabaseName"]       = $config["SqlDatabaseName"] ?? "AzureOptimization"
        }

        # Workspace reuse fields
        if ($config["WorkspaceReuse"] -eq "y") {
            $silentConfig["WorkspaceName"]              = $config["WorkspaceName"]
            $silentConfig["WorkspaceResourceGroupName"] = $config["WorkspaceResourceGroupName"]
        }

        # Benefits fields
        if ($config["DeployBenefitsUsageDependencies"] -eq "y") {
            $silentConfig["CustomerType"]     = $config["CustomerType"]
            $silentConfig["BillingAccountId"] = $config["BillingAccountId"]
            $silentConfig["CurrencyCode"]     = $config["CurrencyCode"]
            if ($config["CustomerType"] -eq "MCA") {
                $silentConfig["BillingProfileId"] = $config["BillingProfileId"]
            }
        }

        # Write silent config to a temp file
        $silentConfigPath = Join-Path $PSScriptRoot "ravl-oe-silent-deploy.json"
        $silentConfig | ConvertTo-Json -Depth 5 | Set-Content -Path $silentConfigPath -Encoding UTF8

        # Build splatted arguments for the deploy script
        $deployArgs = @{
            TemplateUri                  = $templateUri
            AzureEnvironment             = $config["AzureEnvironment"] ?? "AzureCloud"
            SilentDeploymentSettingsPath = $silentConfigPath
            EnableDefaultTelemetry       = [bool]($config["EnableDefaultTelemetry"] ?? $true)
            SqlAdminPrincipalType        = $config["SqlAdminPrincipalType"] ?? "User"
        }

        if ($config["DeploymentMode"] -eq "upgrade") {
            $deployArgs["DoPartialUpgrade"] = $true
        }

        if ($config["IgnoreNamingAvailabilityErrors"]) {
            $deployArgs["IgnoreNamingAvailabilityErrors"] = $true
        }

        if ($config["ResourceTags"] -and $config["ResourceTags"].Count -gt 0) {
            $deployArgs["ResourceTags"] = $config["ResourceTags"]
        }

        if ($config["SqlAdminPrincipalType"] -ne "User") {
            $deployArgs["SqlAdminPrincipalName"]     = $config["SqlAdminPrincipalName"]
            $deployArgs["SqlAdminPrincipalObjectId"] = $config["SqlAdminPrincipalObjectId"]
        }

        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "  Starting Deployment" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "  Template : $templateUri" -ForegroundColor DarkGray
        Write-Host "  Script   : $deployScript" -ForegroundColor DarkGray
        Write-Host ""

        & $deployScript @deployArgs

        # ---- Step 7: Success message ----
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "  Deployment Complete!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "Next step: run Validate-Deployment.ps1 to verify all resources were provisioned correctly." -ForegroundColor Cyan
        Write-Host ""

    } finally {
        # ---- Step 6: Clean up staging resources ----
        if ($stagingContainer -and $stagingStorageAccount) {
            try {
                Write-Host "Cleaning up staging container '$stagingContainer'..." -ForegroundColor DarkGray
                Remove-AzStorageContainer -Name $stagingContainer -Context $stagingStorageAccount.Context -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Host "Warning: Could not remove staging container '$stagingContainer': $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        if ($stagingServer) {
            try {
                Write-Host "Stopping local HTTP listener..." -ForegroundColor DarkGray
                $stagingServer.Stop()
                $stagingServer.Close()
            } catch {
                Write-Host "Warning: Could not stop local HTTP listener: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }

        $silentConfigPath = Join-Path $PSScriptRoot "ravl-oe-silent-deploy.json"
        if (Test-Path $silentConfigPath) {
            Remove-Item $silentConfigPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# Auto-run when script is executed directly
Install-RAVLOptEngine
