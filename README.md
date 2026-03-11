# Azure Files PoC

A self-contained deployment for evaluating Azure Files with Site-to-Site VPN connectivity, private endpoints, identity-based access, and centralized monitoring. Designed to get you from zero to a working SMB file share migration test environment in under an hour (most of that is the VPN gateway provisioning).

## What Gets Deployed

| Resource | Purpose |
|---|---|
| Resource Group | Single RG containing everything |
| Virtual Network (/24) | Hosts subnets for private endpoints and the VPN gateway |
| VPN Gateway (VpnGw1) | Site-to-Site IPsec tunnel back to on-prem |
| Local Network Gateway | Represents your on-prem VPN device |
| Storage Account (Premium FileStorage) | Hosts SMB file shares |
| File Share(s) | One or more shares, configurable via params |
| Private Endpoint + Private DNS Zone | Keeps storage traffic off the public internet |
| NSG | Applied to the private endpoint subnet |
| Log Analytics Workspace | Central log/metrics sink for all resources |
| Azure Shared Dashboard | Portal dashboard for file share observability |

## Prerequisites

- Azure subscription with Contributor access
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) 2.50 or later
- [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) (bundled with az cli)
- [Azure Developer CLI (azd)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) -- only if using the azd deployment path
- PowerShell 7.x -- only if using the deploy.ps1 path
- An on-prem VPN device that supports IKEv2 (for the S2S tunnel)

## Project Structure

```
.
├── azure.yaml                    # AZD project config
├── dashboards/
│   └── azure-files-dashboard.json  # Dashboard template (reference copy)
├── infra/
│   ├── main.bicep                # Subscription-scoped orchestrator
│   ├── main.bicepparam           # User configuration (edit this)
│   └── modules/
│       ├── monitoring.bicep      # Log Analytics + shared dashboard
│       ├── networking.bicep      # VNet, subnets, VPN, NSG
│       └── storage.bicep         # Storage account, shares, PE, RBAC
├── scripts/
│   ├── deploy.ps1                # PowerShell deployment wrapper
│   └── Copy-FilesToAzure.ps1     # SMB data migration script
└── README.md
```

## Configuration

All user-facing configuration lives in `infra/main.bicepparam`. Open it, update the placeholder values, and you're good to go.

Things you need to set before deploying:

| Parameter | What to put here |
|---|---|
| `location` | Azure region (e.g., eastus2, westus2) |
| `projectName` | Short prefix for resource names (lowercase, no special chars, <10 chars) |
| `vnetAddressPrefix` | IP base for the /24 VNet -- pick something that doesn't overlap with on-prem |
| `onPremVpnDeviceIp` | Public IP of your on-prem VPN appliance |
| `onPremAddressSpaces` | On-prem subnet(s) to route through the tunnel |
| `vpnSharedKey` | IPsec pre-shared key -- must match your on-prem device config |
| `fileShareNames` | Array of SMB share names to create |
| `fileShareQuotaGiB` | Capacity per share (premium bills on provisioned GiB) |
| `storageDataContributorPrincipalId` | Entra ID object ID of the group/user that gets SMB data access |
| `tags.Owner` | Your team DL or AD group |

## Deployment

### Option 1: Azure Developer CLI (azd)

```bash
az login
azd init
azd up
```

AZD reads `azure.yaml`, finds the Bicep in `infra/`, and handles the rest. It will prompt for environment name and region.

### Option 2: PowerShell + AzCLI

```powershell
az login
./scripts/deploy.ps1
```

For a dry run (validates the template without deploying):

```powershell
./scripts/deploy.ps1 -WhatIf
```

Both paths deploy the same Bicep template. Pick whichever fits your workflow.

## Post-Deployment Steps

### 1. Configure your on-prem VPN device

The deployment prints the VPN Gateway public IP. Configure your on-prem device with:
- Remote gateway IP: (from deployment output)
- Pre-shared key: (the value you put in the param file)
- IKEv2, route-based

Ref: [VPN device configuration](https://learn.microsoft.com/azure/vpn-gateway/vpn-gateway-about-vpn-devices)

### 2. Set up DNS resolution for private endpoints

On-prem machines need to resolve `*.file.core.windows.net` to the private endpoint IP. Two options:

- **Conditional DNS forwarder**: Point your on-prem DNS server to forward `file.core.windows.net` queries to Azure DNS (168.63.129.16) over the VPN tunnel.
- **Azure DNS Private Resolver**: Deploy a resolver in the VNet and forward to its inbound endpoint IP.

Ref: [Private endpoint DNS configuration](https://learn.microsoft.com/azure/private-link/private-endpoint-dns)

### 3. Domain-join the storage account (for NTFS-level ACLs)

Identity-based access requires the storage account to be joined to your on-prem AD DS. This is a manual step:

Ref: [Enable AD DS authentication for Azure Files](https://learn.microsoft.com/azure/storage/files/storage-files-identity-ad-ds-enable)

### 4. Mount the file share and migrate data

From a domain-joined Windows machine with VPN connectivity:

```powershell
# Mount the share using your AD credentials
net use Z: \\<storageaccount>.file.core.windows.net\department-shared /persistent:yes

# Run the migration script
./scripts/Copy-FilesToAzure.ps1 -SourcePath '\\fileserver01\shared' -DestinationDriveLetter 'Z:'
```

The script uses robocopy to mirror files and icacls to preserve NTFS ACLs. Run with `-WhatIf` first to preview.

Ref: [Copy data to Azure Files](https://learn.microsoft.com/azure/storage/files/storage-files-migration-overview)

### 5. Check the monitoring dashboard

Go to the Azure portal and open the shared dashboard (`dash-<projectName>-azfiles`). It shows:
- Transaction volume and failure rates
- E2E latency percentiles (P50/P95/P99)
- Ingress/egress bandwidth
- Top operations by count
- Detailed error log (HTTP 4xx/5xx)

Data shows up once the storage account starts getting traffic (after you mount and use the shares).

## Cost Estimates

Rough monthly costs for a minimal PoC (100 GiB provisioned, light usage):

| Resource | Estimated Monthly Cost |
|---|---|
| VPN Gateway (VpnGw1) | ~$140 |
| Premium Files (per 100 GiB) | ~$16 |
| Log Analytics (PerGB2018) | ~$2.76/GB ingested |
| Private Endpoint | ~$7.30 + $0.01/GB |
| Standard Public IP | ~$3.65 |
| **Total (ballpark)** | **$170-200/mo** |

The VPN gateway is by far the biggest cost. If you're just testing storage without needing the tunnel, you can skip the VPN (comment out the gateway resources in networking.bicep) and bring costs down to ~$25-30/mo.

## Cleanup

```bash
# Delete the entire resource group
az group delete --name rg-<projectName>-poc --yes --no-wait
```

Or with azd:

```bash
azd down
```

## References

- [Azure Files planning guide](https://learn.microsoft.com/azure/storage/files/storage-files-planning)
- [Azure Files identity-based authentication](https://learn.microsoft.com/azure/storage/files/storage-files-active-directory-overview)
- [Azure Private Link for Storage](https://learn.microsoft.com/azure/storage/common/storage-private-endpoints)
- [VPN Gateway documentation](https://learn.microsoft.com/azure/vpn-gateway/vpn-gateway-about-vpngateways)
- [Azure Monitor Logs](https://learn.microsoft.com/azure/azure-monitor/logs/log-analytics-overview)
- [Azure portal dashboards](https://learn.microsoft.com/azure/azure-portal/azure-portal-dashboards)
