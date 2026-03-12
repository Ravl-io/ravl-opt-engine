# RAVLs Optimization Engine Automation Runbooks

This folder contains the Azure Automation Runbooks executed periodically by ROE to collect data from multiple cloud providers and generate optimization recommendations.

## Directory Structure

- [data-collection](./data-collection/) - runbooks collecting data from Azure (Resource Graph, Monitor, Billing APIs, etc.), AWS, and GCP sources, exporting to Azure Storage, and ingesting into custom Log Analytics tables.
  - [aws](./data-collection/aws/) - AWS data collection via distributor VM (EC2, EBS, EIP, RDS, Lambda, ECS, Elastic Beanstalk, S3)
  - [gcp](./data-collection/gcp/) - GCP data collection via distributor VM (VMs, disks, IPs, Cloud SQL, services, load balancers, GCS, FOCUS)
- [maintenance](./maintenance/) - runbooks executing periodic data cleansing (e.g., recommendations retention policy).
- [orchestration](./orchestration/) - orchestrator runbooks coordinating task execution across the distributor VM.
- [recommendations](./recommendations/) - runbooks generating weekly recommendations by querying Log Analytics, exporting to Azure Storage, and ingesting into Log Analytics and SQL Database.
  - [aws](./recommendations/aws/) - AWS optimization recommendations
  - [gcp](./recommendations/gcp/) - GCP optimization recommendations
- [remediations](./remediations/) - runbooks automating remediation of optimization recommendations (**turned off by default**).

## Multi-Cloud Support

AWS and GCP runbooks are deployed with schedules **disabled by default**. Enable them after completing the cloud-specific setup below.

### AWS/GCP Architecture

AWS and GCP **Export** runbooks use `Set-AzVMRunCommand` to execute shell scripts on a dedicated Linux VM (the "distributor VM") that has AWS CLI and GCP `gcloud`/`bq` CLI tools installed. AWS/GCP **Recommend** runbooks process CSV exports from blob storage directly in PowerShell.

### AWS Setup

1. Deploy a Linux distributor VM with AWS CLI installed and configured
2. Deploy AWS collection scripts to the VM (default: `/home/AZIGMADMIN/finops-aws/AWS_Exporting`)
3. Configure IAM with read-only access to target AWS services
4. Set automation variables: `AzureOptimization_AWSEnabled=true`, `AzureOptimization_DistributorVmName`, `AzureOptimization_DistributorVmRG`
5. Enable AWS schedules in Azure Automation
6. Run deployment with `-EnableAWS $true` to create the `awsexports` storage container

### GCP Setup

1. Use the same distributor VM with `gcloud` CLI installed and configured
2. Deploy GCP collection scripts to the VM (default: `/home/AZIGMADMIN/finops-gcp/GCP_Exporting`)
3. Configure a GCP service account with Viewer role on target projects
4. Set automation variables: `AzureOptimization_GCPEnabled=true`, `AzureOptimization_DistributorVmName`, `AzureOptimization_DistributorVmRG`
5. Enable GCP schedules in Azure Automation
6. Run deployment with `-EnableGCP $true` to create the `gcpexports` storage container

**Note:** `GCP-IngestFOCUS.ps1` requires a Hybrid Runbook Worker with `gcloud` and `bq` CLI installed (not available in Azure Automation sandbox).

### Authentication

All runbooks use Managed Identity (system-assigned or user-assigned) for Azure authentication. UAMI is supported via `AzureOptimization_AuthenticationOption=UserAssignedManagedIdentity` and `AzureOptimization_UAMIClientID`.

See `docs/superpowers/specs/2026-03-22-runbook-merge-design.md` for full setup details.
