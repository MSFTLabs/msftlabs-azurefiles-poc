#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the Azure Files PoC infrastructure using AzCLI + Bicep.

.DESCRIPTION
    This is the "no AZD" deployment path. It wraps az cli commands to:
      1. Validate you're logged in and have the right subscription selected
      2. Run the Bicep deployment at subscription scope
      3. Print a clean summary of what got deployed and rough cost estimates

    If you prefer AZD, just run "azd up" from the project root instead.

.PARAMETER ParameterFile
    Path to the .bicepparam file. Defaults to infra/main.bicepparam.

.PARAMETER Location
    Azure region for the deployment metadata (not the resources -- those come
    from the param file). Defaults to eastus2.

.PARAMETER WhatIf
    Run in validation-only mode. Nothing gets deployed, but you'll see if the
    template would succeed.

.EXAMPLE
    ./scripts/deploy.ps1
    ./scripts/deploy.ps1 -Location westus2 -WhatIf

.NOTES
    Requires: Azure CLI 2.50+, Bicep CLI (bundled with az cli), PowerShell 7.x
    Ref: https://learn.microsoft.com/cli/azure/deployment/sub?view=azure-cli-latest
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ParameterFile = (Join-Path $PSScriptRoot '..' 'infra' 'main.bicepparam'),
    [string]$Location = 'eastus2'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helper: write colored status lines without the verbose PowerShell prefix
# ---------------------------------------------------------------------------
function Write-Status {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Message" -ForegroundColor $Color
}

# ---------------------------------------------------------------------------
# Pre-flight: make sure az cli is available and user is logged in
# ---------------------------------------------------------------------------
Write-Status 'Checking Azure CLI is installed and you are logged in...'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error 'Azure CLI (az) not found. Install it: https://learn.microsoft.com/cli/azure/install-azure-cli'
}

$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Error 'Not logged in. Run "az login" first.'
}

Write-Status "Subscription: $($account.name) ($($account.id))"
Write-Status "Deploying to region: $Location"

# Resolve full path to param file so relative paths work from any cwd
$ParameterFile = (Resolve-Path $ParameterFile).Path
$templateFile = Join-Path (Split-Path $ParameterFile) 'main.bicep'

if (-not (Test-Path $templateFile)) {
    Write-Error "Template not found at $templateFile"
}
if (-not (Test-Path $ParameterFile)) {
    Write-Error "Parameter file not found at $ParameterFile"
}

# ---------------------------------------------------------------------------
# Deploy or validate
# ---------------------------------------------------------------------------
$deploymentName = "azfiles-poc-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

if ($WhatIf) {
    Write-Status 'Running validation only (WhatIf mode)...' 'Yellow'
    az deployment sub validate `
        --name $deploymentName `
        --location $Location `
        --template-file $templateFile `
        --parameters $ParameterFile `
        --output table

    if ($LASTEXITCODE -ne 0) {
        Write-Error 'Validation failed. Check the errors above.'
    }
    Write-Status 'Validation passed.' 'Green'
    return
}

Write-Status 'Starting deployment -- VPN gateway takes 25-40 min, so this will take a while...'

$result = az deployment sub create `
    --name $deploymentName `
    --location $Location `
    --template-file $templateFile `
    --parameters $ParameterFile `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment failed:`n$result"
}

$deployment = $result | ConvertFrom-Json

# ---------------------------------------------------------------------------
# Output summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '============================================================' -ForegroundColor Green
Write-Host '  Azure Files PoC -- Deployment Complete' -ForegroundColor Green
Write-Host '============================================================' -ForegroundColor Green
Write-Host ''

$outputs = $deployment.properties.outputs

$summary = [ordered]@{
    'Resource Group'          = $outputs.resourceGroupName.value
    'Storage Account'         = $outputs.storageAccountName.value
    'File Endpoint'           = $outputs.storageAccountFileEndpoint.value
    'File Shares'             = ($outputs.fileShareNames.value -join ', ')
    'VNet'                    = $outputs.vnetName.value
    'VPN Gateway Public IP'   = $outputs.vpnGatewayPublicIp.value
    'Log Analytics Workspace' = $outputs.logAnalyticsWorkspaceName.value
    'Dashboard'               = $outputs.dashboardName.value
}

foreach ($kv in $summary.GetEnumerator()) {
    Write-Host "  $($kv.Key.PadRight(26)) : $($kv.Value)" -ForegroundColor White
}

Write-Host ''
Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host '  Estimated Monthly Costs (rough ballpark):' -ForegroundColor Yellow
Write-Host '    VPN Gateway (VpnGw1)       : ~$140/mo' -ForegroundColor White
Write-Host '    Storage (Premium Files)     : ~$0.16/GiB provisioned/mo' -ForegroundColor White
Write-Host '    Log Analytics (PerGB2018)   : ~$2.76/GB ingested/mo' -ForegroundColor White
Write-Host '    Private Endpoint            : ~$7.30/mo + $0.01/GB processed' -ForegroundColor White
Write-Host '    Public IP (Standard)        : ~$3.65/mo' -ForegroundColor White
Write-Host '' 
Write-Host '  Total for a minimal PoC with 100 GiB provisioned:' -ForegroundColor White
Write-Host '    Roughly $170-200/mo (VPN gateway is the big one)' -ForegroundColor White
Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host ''
Write-Status 'Done. Next steps:' 'Green'
Write-Host '  1. Configure your on-prem VPN device with the gateway public IP above'
Write-Host '  2. Set up DNS conditional forwarding for *.file.core.windows.net'
Write-Host '  3. Run scripts/Copy-FilesToAzure.ps1 to migrate file share data'
Write-Host '  4. Check the Azure portal dashboard for monitoring'
Write-Host ''
