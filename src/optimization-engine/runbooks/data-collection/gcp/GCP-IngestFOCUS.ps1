$ErrorActionPreference = "Stop"

# --- Configuration variables from Automation Account ---
$gcpProjectId           = Get-AutomationVariable -Name "GCP_Project_ID"
$bigQueryDataset        = Get-AutomationVariable -Name "GCP_BigQuery_Dataset"
$bigQueryTable          = Get-AutomationVariable -Name "GCP_BigQuery_Table"
$storageAccountName     = Get-AutomationVariable -Name "FinOps_StorageAccount"
$containerName          = Get-AutomationVariable -Name "FinOps_Container"
$gcpProjectNumber       = Get-AutomationVariable -Name "GCP_Project_Number"
$workloadIdentityPoolId = Get-AutomationVariable -Name "GCP_workloadIdentityPoolId"
$gcpServiceAccount      = Get-AutomationVariable -Name "GCP_Service_Account"

# GCP Federation Config (set directly here or via variables if preferred)

$targetFileName     = "gcp-focus-export-$(Get-Date -Format yyyy-MM-dd).csv"

# --- Step 1: Authenticate to Azure ---
Connect-AzAccount -Identity

# --- Step 2: Request an OIDC token from Azure Instance Metadata Service ---
$resource = "api://AzureADTokenExchange"
$tokenResponse = Invoke-RestMethod -Method Get -Headers @{Metadata="true"} `
  -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=$resource"
$oidcToken = $tokenResponse.access_token

# --- Step 3: Save OIDC token and credentials config for gcloud ---
$oidcTokenPath = "$env:TEMP\oidc-token.txt"
$gcpCredsPath  = "$env:TEMP\gcp-oidc-creds.json"
$oidcToken | Out-File -FilePath $oidcTokenPath -Encoding ascii

@"
{
  "type": "external_account",
  "audience": "//iam.googleapis.com/projects/$gcpProjectNumber/locations/global/workloadIdentityPools/$workloadIdentityPoolId/providers/$workloadIdentityPoolId",
  "subject_token_type": "urn:ietf:params:oauth:token-type:jwt",
  "token_url": "https://sts.googleapis.com/v1/token",
  "credential_source": {
    "file": "$oidcTokenPath"
  },
  "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/$gcpServiceAccount:generateAccessToken"
}
"@ | Out-File -FilePath $gcpCredsPath -Encoding ascii

# --- Step 4: Authenticate to GCP ---
& gcloud auth login --cred-file=$gcpCredsPath --brief
& gcloud config set project $gcpProjectId

# --- Export from BigQuery to CSV ---
$outputPath = "$env:TEMP\$targetFileName"

$bqQuery = @"
SELECT * FROM `$gcpProjectId.$bigQueryDataset.$bigQueryTable
"@

& bq query --nouse_legacy_sql `
  --format=csv `
  --project_id=$gcpProjectId `
  "$bqQuery" > $outputPath

# --- Upload to Azure Storage ---
$ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseManagedIdentity
Set-AzStorageBlobContent -File $outputPath -Container $containerName -Blob "ingestion/$targetFileName" -Context $ctx

Write-Output "GCP billing data exported and uploaded successfully to Azure Storage."