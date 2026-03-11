// ============================================================================
// storage.bicep - Storage Account, File Shares, Private Endpoint, DNS, RBAC
//
// Creates a storage account optimized for Azure Files, provisions the
// requested file shares, locks it down with a private endpoint + private
// DNS zone, and assigns RBAC for SMB data plane access.
//
// Why Private Endpoints:
//   Without a PE, file share traffic goes over the public internet (even
//   with "allow trusted services" or VNet rules). For a migration PoC that
//   simulates production, we want all SMB traffic on the private network
//   via the S2S VPN tunnel. The PE puts a NIC in our VNet and the private
//   DNS zone resolves *.file.core.windows.net to that private IP.
//
// Why RBAC instead of storage account keys:
//   Microsoft's guidance is to use identity-based auth (Entra ID / AD DS)
//   for Azure Files SMB access. The "Storage File Data SMB Share Contributor"
//   role gives read/write/delete on files without needing to hand out
//   storage account keys.
//
// Ref: https://learn.microsoft.com/azure/storage/files/storage-files-planning
// Ref: https://learn.microsoft.com/azure/storage/files/storage-files-identity-auth-active-directory-enable
// Ref: https://learn.microsoft.com/azure/private-link/private-endpoint-overview
// ============================================================================

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

param location string
param projectName string
param tags object

@description('Storage SKU -- passed in from main.bicep variables (hardcoded).')
param storageSkuName string

@description('Storage Kind -- passed in from main.bicep variables (hardcoded).')
param storageKind string

@description('List of file share names to create.')
param fileShareNames array

@description('Quota per share in GiB.')
param fileShareQuotaGiB int

@description('Resource ID of the PE subnet.')
param privateEndpointSubnetId string

@description('Resource ID of the VNet (needed for DNS zone link).')
param vnetId string

@description('Resource ID of the Log Analytics workspace for diagnostics.')
param logAnalyticsWorkspaceId string

@description('Object ID of the principal getting data plane RBAC.')
param dataContributorPrincipalId string

@description('Principal type for the RBAC assignment.')
param dataContributorPrincipalType string

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

// Storage account names must be globally unique, 3-24 chars, lowercase + numbers only.
// We append a deterministic 6-char suffix from the resource group ID to avoid collisions.
var storageAccountName = toLower('st${projectName}${uniqueString(resourceGroup().id)}')
var privateEndpointName = 'pe-${storageAccountName}-file'
var privateDnsZoneName = 'privatelink.file.${environment().suffixes.storage}'

// "Storage File Data SMB Share Contributor" built-in role
// Ref: https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#storage-file-data-smb-share-contributor
var storageSmbContributorRoleId = '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'

// ---------------------------------------------------------------------------
// Storage Account (via AVM)
//
// Key settings:
//  - publicNetworkAccess: Disabled. All access goes through the PE.
//  - minimumTlsVersion: TLS1_2. Anything lower is insecure.
//  - supportsHttpsTrafficOnly: true. SMB 3.x over HTTPS for encryption in transit.
//  - fileServices.shares: created inline from the fileShareNames param.
//
// Ref: https://learn.microsoft.com/azure/storage/files/storage-files-planning#storage-account-settings
// ---------------------------------------------------------------------------

module storageAccount 'br/public:avm/res/storage/storage-account:0.32.0' = {
  name: 'storage-deployment'
  params: {
    name: storageAccountName
    location: location
    tags: tags
    skuName: storageSkuName
    kind: storageKind
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    minimumTlsVersion: 'TLS1_2'
    allowSharedKeyAccess: false
    fileServices: {
      shares: [for shareName in fileShareNames: {
        name: shareName
        shareQuota: fileShareQuotaGiB
        enabledProtocols: 'SMB'
      }]
      diagnosticSettings: [
        {
          workspaceResourceId: logAnalyticsWorkspaceId
        }
      ]
    }
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalyticsWorkspaceId
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Private DNS Zone for Azure Files
//
// Creates the privatelink.file.core.windows.net zone and links it to our VNet.
// When machines in the VNet (or on-prem via the VPN + DNS forwarding) resolve
// storageaccount.file.core.windows.net, they get the PE private IP instead of
// the public endpoint.
//
// For on-prem resolution, you'll need a conditional forwarder on your DNS
// server pointing *.file.core.windows.net to the Azure DNS resolver
// (168.63.129.16) -- or use Azure DNS Private Resolver.
//
// Ref: https://learn.microsoft.com/azure/private-link/private-endpoint-dns
// ---------------------------------------------------------------------------

module privateDnsZone 'br/public:avm/res/network/private-dns-zone:0.8.1' = {
  name: 'dns-zone-deployment'
  params: {
    name: privateDnsZoneName
    tags: tags
    virtualNetworkLinks: [
      {
        virtualNetworkResourceId: vnetId
        registrationEnabled: false
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Private Endpoint for the Storage Account (file sub-resource)
//
// Puts a NIC in the PE subnet that represents the storage account's file
// endpoint. Traffic to the storage account from anything on the VNet (or
// on-prem through the VPN) stays entirely on the Microsoft backbone.
//
// Ref: https://learn.microsoft.com/azure/storage/common/storage-private-endpoints
// ---------------------------------------------------------------------------

module privateEndpoint 'br/public:avm/res/network/private-endpoint:0.12.0' = {
  name: 'pe-deployment'
  params: {
    name: privateEndpointName
    location: location
    tags: tags
    subnetResourceId: privateEndpointSubnetId
    privateLinkServiceConnections: [
      {
        name: privateEndpointName
        properties: {
          privateLinkServiceId: storageAccount.outputs.resourceId
          groupIds: [
            'file'
          ]
        }
      }
    ]
    privateDnsZoneGroup: {
      privateDnsZoneGroupConfigs: [
        {
          privateDnsZoneResourceId: privateDnsZone.outputs.resourceId
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// RBAC: Storage File Data SMB Share Contributor
//
// Grants the specified principal (usually an AD group) read/write/delete
// permissions on file share data via SMB. This is the data plane role --
// it doesn't grant control plane access (can't delete the storage account,
// manage keys, etc.).
//
// For the full identity-based auth flow with on-prem AD DS, you also need
// to domain-join the storage account. That's a manual step covered in the
// README and migration script.
//
// Ref: https://learn.microsoft.com/azure/storage/files/storage-files-identity-ad-ds-assign-permissions
// ---------------------------------------------------------------------------

resource smbContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, dataContributorPrincipalId, storageSmbContributorRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageSmbContributorRoleId)
    principalId: dataContributorPrincipalId
    principalType: dataContributorPrincipalType
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output storageAccountName string = storageAccount.outputs.name
output storageAccountId string = storageAccount.outputs.resourceId
output storageAccountFileEndpoint string = 'https://${storageAccount.outputs.name}.file.${environment().suffixes.storage}'
output fileShareNames array = fileShareNames
output privateEndpointIp string = privateEndpoint.outputs.?groupId ?? ''
