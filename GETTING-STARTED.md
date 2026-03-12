# Getting Started with RAVLs Optimization Engine

## Prerequisites

- **Azure subscription** with Contributor or Owner role
- **PowerShell 7+** — [download here](https://aka.ms/powershell)
- **Az PowerShell module** — `Install-Module Az -Scope CurrentUser -Force`
- **Signed in to Azure** — `Connect-AzAccount`

## Quick Start

```powershell
git clone https://github.com/Ravl-io/ravl-opt-engine.git
cd ravl-opt-engine/src/optimization-engine
pwsh ./Install-RAVLOptEngine.ps1
```

The installer launches an interactive wizard. It detects existing deployments automatically and prompts only for what it needs. Your answers are saved to `ravl-oe-config.json` for future upgrades.

## What Gets Deployed

| Resource | Purpose |
|---|---|
| **Automation Account** | Hosts 92 runbooks for export, ingest, recommendation, and remediation |
| **Storage Account** | Blob containers for CSV exports from each data source |
| **Azure SQL** | Stores processed cost and utilisation data for workbook queries |
| **Log Analytics Workspace** | Centralised logging and query backend for workbooks |
| **Azure Workbooks** | Pre-built dashboards for VM rightsizing, cost anomalies, and more |

## Post-Install Validation

Run the health check script immediately after installation:

```powershell
pwsh ./Validate-Deployment.ps1
```

This runs 8 checks: resource existence, runbook count, automation variables, storage containers, SQL connectivity, schedules, a live export test, and blob output verification.

To skip the live export test (faster, useful in CI):

```powershell
pwsh ./Validate-Deployment.ps1 -Quick
```

Expected output:

```
RAVLs Optimization Engine Health Check
=======================================
[PASS] Resource group: ravl-optimization-engine
[PASS] Automation account: ravloptaa (92 runbooks)
[PASS] Core automation variables
[PASS] Storage containers
[PASS] SQL connectivity
[PASS] Automation schedules
[PASS] Test export (Export-ARGResourceContainersPropertiesToBlobStorage)
[PASS] Blob output in 'argrescontainersexports'

Result: 8/8 passed. Engine is healthy.
```

## Adding AWS

AWS data collection requires a **Distributor VM** — a Linux VM in Azure running the finops-aws scripts as a Hybrid Runbook Worker. Once the VM is ready:

```powershell
pwsh ./Setup-AWSCloud.ps1
```

The script will ask for the VM name, resource group, location, and scripts path, then configure the required automation variables, storage container, and schedules.

## Adding GCP

GCP data collection also requires a Distributor VM, with `gcloud` and `bq` (BigQuery CLI) installed and authenticated. The `GCP-IngestFOCUS.ps1` runbook **cannot** run on standard Azure Automation sandbox workers.

```powershell
pwsh ./Setup-GCPCloud.ps1
```

## Upgrading

Re-run the installer. It detects `ravl-oe-config.json` and `last-deployment-state.json` automatically and defaults to upgrade mode. Your existing configuration is used as defaults — you only need to confirm or change values.

```powershell
pwsh ./Install-RAVLOptEngine.ps1
```

## Troubleshooting

**SQL deployment fails with region error**
Azure SQL is not available in all regions. Choose a supported region such as `eastus`, `eastus2`, `canadacentral`, or `westeurope`. Run `Get-AzSqlCapability -LocationName <region>` to check availability.

**Az module version errors**
Some features require specific Az module versions. Run `Update-Module Az -Force` to update, then restart your PowerShell session.

**Role assignment conflicts**
If you see `RoleAssignmentExists` errors during deployment, the role was already assigned. This is safe to ignore — re-run the installer and it will skip the conflicting assignment.

**Partial deployment recovery**
If the deployment stops partway through, re-run `Install-RAVLOptEngine.ps1`. ARM deployments are idempotent — resources that already exist will be skipped and missing ones will be created. The installer will also re-upload any missing runbooks and variables.

**Runbooks failing on first run**
Schedules fire within 1 hour of deployment. If jobs fail immediately, check the Automation Account job logs in the Azure portal. Common causes: SQL firewall blocking the worker IP, or a missing automation variable.

## Uninstalling

To remove all resources, delete the resource group:

```bash
az group delete --name ravl-optimization-engine --yes
```

This is irreversible. All exported data, SQL databases, runbooks, and workbooks will be permanently deleted.
