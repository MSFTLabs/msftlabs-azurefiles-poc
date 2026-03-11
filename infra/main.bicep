// ============================================================================
// main.bicep - Azure Files PoC Deployment Orchestrator
// Scope: Subscription
//
// This is the top-level template that creates the resource group(s) and calls
// workload-specific modules. It's designed to be called by either AZD or the
// deploy.ps1 wrapper script.
//
// Storage SKU and Kind are pinned as variables here (not params) so that
// downstream consumers can't accidentally pick a config that breaks the PoC.
//
// Ref: https://learn.microsoft.com/azure/azure-resource-manager/bicep/
// ============================================================================

targetScope = 'subscription'

// ---------------------------------------------------------------------------
// Parameters - these are the knobs end-users turn via main.bicepparam
// ---------------------------------------------------------------------------

@description('Azure region for all resources. Defaults to the deployment location.')
param location string

@description('Short name used as a prefix/suffix for resource naming. Keep it under 10 chars.')
@minLength(2)
@maxLength(10)
param projectName string

@description('Base address space for the VNet. Must be a valid /24 network address (just the IP portion). Default: 10.0.0.0')
param vnetAddressPrefix string = '10.0.0.0'

@description('Array of file share names to create. At least one is required.')
@minLength(1)
param fileShareNames array

@description('Quota in GiB for each file share. Default: 100')
param fileShareQuotaGiB int = 100

@description('VPN shared key for the S2S connection. Treat this like a password.')
@secure()
param vpnSharedKey string

@description('Public IP of the on-prem VPN device.')
param onPremVpnDeviceIp string

@description('On-prem address space(s) that should route through the VPN tunnel. E.g., ["192.168.1.0/24"]')
param onPremAddressSpaces array

@description('Object ID of the AD group or user that gets "Storage File Data SMB Share Contributor" on the file shares.')
param storageDataContributorPrincipalId string

@description('Principal type for the RBAC assignment. Usually "Group" for AD groups or "User" for individual accounts.')
@allowed(['Group', 'User', 'ServicePrincipal'])
param storageDataContributorPrincipalType string = 'Group'

@description('Resource tags applied to everything. Owner and Environment are required by the PoC.')
param tags object

// ---------------------------------------------------------------------------
// Variables - intentionally hardcoded so the PoC stays on a known-good config
// ---------------------------------------------------------------------------

// Storage account SKU and Kind are fixed. FileStorage + Premium_LRS gives us
// premium SMB shares (required for production-like perf testing). If you need
// standard tier for cost reasons, swap to StorageV2 + Standard_LRS, but know
// that performance characteristics will be very different.
var storageSkuName = 'Premium_LRS'
var storageKind = 'FileStorage'

// Resource group name derived from the project name so it's predictable
var resourceGroupName = 'rg-${projectName}-poc'

// ---------------------------------------------------------------------------
// Resource Group - created at subscription scope, everything else goes inside
// ---------------------------------------------------------------------------

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// ---------------------------------------------------------------------------
// Module: Monitoring
// Deployed first because other modules need the LAW resource ID so they can
// wire up diagnostic settings.
// ---------------------------------------------------------------------------

module monitoring 'modules/monitoring.bicep' = {
  scope: rg
  params: {
    location: location
    projectName: projectName
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Module: Networking
// VNet, subnets, NSG, VPN Gateway, and S2S connection. The VPN gateway takes
// ~25-40 min to provision -- that's normal, don't kill the deployment.
// ---------------------------------------------------------------------------

module networking 'modules/networking.bicep' = {
  scope: rg
  params: {
    location: location
    projectName: projectName
    vnetAddressPrefix: vnetAddressPrefix
    vpnSharedKey: vpnSharedKey
    onPremVpnDeviceIp: onPremVpnDeviceIp
    onPremAddressSpaces: onPremAddressSpaces
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Module: Storage
// Storage account, file shares, private endpoint, private DNS zone, and RBAC.
// Depends on networking (needs subnet ID for the private endpoint) and
// monitoring (needs LAW ID for diagnostic settings).
// ---------------------------------------------------------------------------

module storage 'modules/storage.bicep' = {
  scope: rg
  params: {
    location: location
    projectName: projectName
    storageSkuName: storageSkuName
    storageKind: storageKind
    fileShareNames: fileShareNames
    fileShareQuotaGiB: fileShareQuotaGiB
    privateEndpointSubnetId: networking.outputs.privateEndpointSubnetId
    vnetId: networking.outputs.vnetId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    dataContributorPrincipalId: storageDataContributorPrincipalId
    dataContributorPrincipalType: storageDataContributorPrincipalType
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Outputs - surfaced to the caller (AZD or deploy.ps1) for post-deployment
// ---------------------------------------------------------------------------

output resourceGroupName string = rg.name
output storageAccountName string = storage.outputs.storageAccountName
output storageAccountFileEndpoint string = storage.outputs.storageAccountFileEndpoint
output fileShareNames array = storage.outputs.fileShareNames
output vnetName string = networking.outputs.vnetName
output vpnGatewayPublicIp string = networking.outputs.vpnGatewayPublicIp
output logAnalyticsWorkspaceName string = monitoring.outputs.logAnalyticsWorkspaceName
output dashboardName string = monitoring.outputs.dashboardName
