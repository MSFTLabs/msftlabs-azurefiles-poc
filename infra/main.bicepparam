// ============================================================================
// main.bicepparam - User Configuration for Azure Files PoC
//
// This is the ONLY file end-users should edit. All deployment-time knobs
// live here. Adjust values below to match your environment.
//
// Ref: https://learn.microsoft.com/azure/azure-resource-manager/bicep/parameter-files
// ============================================================================

using './main.bicep'

// -- Region ------------------------------------------------------------------
// Pick the Azure region closest to your on-prem site for lowest latency.
param location = 'eastus2'

// -- Project Name ------------------------------------------------------------
// Short prefix used in resource names. Keep it lowercase, no special chars.
param projectName = 'azfiles'

// -- Tags --------------------------------------------------------------------
// Required by the PoC. Update OWNER to your team DL or AD group.
param tags = {
  Owner: 'DL or GROUP'
  Environment: 'PoC'
  Project: 'Azure Files Migration PoC'
}

// -- Networking --------------------------------------------------------------
// Base /24 address space for the PoC VNet. Just the IP, the /24 mask is
// appended automatically in the Bicep. Make sure this doesn't overlap with
// your on-prem ranges.
param vnetAddressPrefix = '10.0.0.0'

// -- VPN (Site-to-Site) ------------------------------------------------------
// Public IP of your on-prem VPN appliance (firewall, router, etc.)
param onPremVpnDeviceIp = '203.0.113.1'

// On-prem subnets that should be reachable through the tunnel
param onPremAddressSpaces = [
  '192.168.1.0/24'
]

// Pre-shared key for the IPsec tunnel. Change this to something strong.
param vpnSharedKey = '<REPLACE-WITH-STRONG-PSK>'

// -- Storage -----------------------------------------------------------------
// Names of the SMB file shares to create. Add/remove entries as needed.
param fileShareNames = [
  'department-shared'
  'project-data'
]

// Per-share quota in GiB. Premium tier bills on provisioned capacity so
// right-size this for your test data volume.
param fileShareQuotaGiB = 100

// -- RBAC --------------------------------------------------------------------
// Object ID of the AD group (or user) that needs read/write access to the
// file shares. This gets "Storage File Data SMB Share Contributor".
// Find it: az ad group show --group "YourGroupName" --query id -o tsv
param storageDataContributorPrincipalId = '<REPLACE-WITH-AAD-OBJECT-ID>'

// Set to 'User' if assigning to an individual instead of a group.
param storageDataContributorPrincipalType = 'Group'
