// ============================================================================
// networking.bicep - VNet, Subnets, NSG, VPN Gateway, S2S Connection
//
// Builds the network plumbing for the PoC:
//  - VNet with a /24 address space
//  - PrivateEndpointSubnet (/27) for storage private endpoints
//  - GatewaySubnet (/27) required by the VPN gateway
//  - NSG on the PE subnet (GatewaySubnet can't have a custom NSG)
//  - VPN Gateway (VpnGw1, route-based) with a public IP
//  - Local Network Gateway representing the on-prem side
//  - S2S VPN connection tying them together
//
// The VPN gateway provisioning takes 25-40 minutes. That's the Azure fabric
// allocating dedicated gateway instances -- nothing is broken, it just takes
// a while.
//
// Subnet offsets use the cidrSubnet() function so we don't have to manually
// carve up the address space. Given a /24 input:
//   cidrSubnet('10.0.0.0/24', 27, 0) => 10.0.0.0/27   (GatewaySubnet)
//   cidrSubnet('10.0.0.0/24', 27, 1) => 10.0.0.32/27  (PrivateEndpointSubnet)
//
// Ref: https://learn.microsoft.com/azure/vpn-gateway/vpn-gateway-about-vpngateways
// Ref: https://learn.microsoft.com/azure/private-link/private-endpoint-overview
// ============================================================================

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

param location string
param projectName string
param vnetAddressPrefix string
param tags object

@secure()
param vpnSharedKey string
param onPremVpnDeviceIp string
param onPremAddressSpaces array
param logAnalyticsWorkspaceId string

// ---------------------------------------------------------------------------
// Variables
// ---------------------------------------------------------------------------

// Assemble the /24 CIDR from the user-supplied base address
var vnetCidr = '${vnetAddressPrefix}/24'

// Carve subnets out of the /24 using cidrSubnet
// Index 0 = GatewaySubnet, Index 1 = PrivateEndpointSubnet
var gatewaySubnetCidr = cidrSubnet(vnetCidr, 27, 0)
var peSubnetCidr = cidrSubnet(vnetCidr, 27, 1)

var vnetName = 'vnet-${projectName}-poc'
var nsgName = 'nsg-${projectName}-pe'
var vpnGwName = 'vpngw-${projectName}-poc'
var vpnGwPipName = 'pip-${vpnGwName}'
var lgwName = 'lgw-${projectName}-onprem'
var connectionName = 'cn-${projectName}-s2s'

// ---------------------------------------------------------------------------
// NSG for the Private Endpoint subnet
//
// Private endpoints don't strictly need NSG rules to function, but having
// an NSG attached satisfies most org policies and gives you a place to add
// deny rules if needed later. We start with the default allow-all baseline.
//
// GatewaySubnet does NOT get an NSG -- Azure blocks that and the deployment
// will fail if you try.
//
// Ref: https://learn.microsoft.com/azure/private-link/private-endpoint-overview#network-security-of-private-endpoints
// ---------------------------------------------------------------------------

module nsg 'br/public:avm/res/network/network-security-group:0.5.2' = {
  name: 'nsg-deployment'
  params: {
    name: nsgName
    location: location
    tags: tags
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalyticsWorkspaceId
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Virtual Network + Subnets (via AVM)
//
// Two subnets:
//  - GatewaySubnet: name is mandatory for VPN gateway. /27 = 32 IPs, Azure
//    uses 5, plenty for a single-instance gateway.
//  - PrivateEndpointSubnet: where the storage PE NIC lands. /27 is overkill
//    for a PoC but keeps CIDR math simple and leaves room for growth.
//
// Ref: https://learn.microsoft.com/azure/virtual-network/virtual-networks-overview
// ---------------------------------------------------------------------------

module vnet 'br/public:avm/res/network/virtual-network:0.7.2' = {
  name: 'vnet-deployment'
  params: {
    name: vnetName
    location: location
    tags: tags
    addressPrefixes: [
      vnetCidr
    ]
    subnets: [
      {
        // Azure requires this exact name for VPN gateway subnets -- no alias
        name: 'GatewaySubnet'
        addressPrefix: gatewaySubnetCidr
      }
      {
        name: 'PrivateEndpointSubnet'
        addressPrefix: peSubnetCidr
        networkSecurityGroupResourceId: nsg.outputs.resourceId
      }
    ]
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalyticsWorkspaceId
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Public IP for the VPN Gateway
//
// Standard SKU + Static allocation is required for VpnGw1 and above.
// Ref: https://learn.microsoft.com/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings#gwpip
// ---------------------------------------------------------------------------

resource vpnGwPip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: vpnGwPipName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// Diagnostic settings for the PIP -- send to LAW for troubleshooting
resource vpnGwPipDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'pip-diag'
  scope: vpnGwPip
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// VPN Gateway (via AVM)
//
// VpnGw1 is the smallest production SKU and supports up to 650 Mbps.
// Route-based is required for S2S with most modern firewalls.
// BGP is disabled to keep the PoC simple -- static routes via the Local
// Network Gateway handle everything.
//
// This takes 25-40 min to provision. Grab a coffee.
//
// Ref: https://learn.microsoft.com/azure/vpn-gateway/vpn-gateway-about-vpngateways
// ---------------------------------------------------------------------------

module vpnGateway 'br/public:avm/res/network/virtual-network-gateway:0.10.1' = {
  name: 'vpngw-deployment'
  params: {
    name: vpnGwName
    location: location
    tags: tags
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    skuName: 'VpnGw1'
    // Tie to the GatewaySubnet we created above
    virtualNetworkResourceId: vnet.outputs.resourceId
    // Use the existing public IP we created above
    existingPrimaryPublicIPResourceId: vpnGwPip.id
    // Active-passive is fine for a PoC
    clusterSettings: {
      clusterMode: 'activePassiveNoBgp'
    }
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalyticsWorkspaceId
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Local Network Gateway
//
// Represents the on-prem side of the VPN tunnel. The public IP is your
// firewall/router's WAN interface and the address spaces are the on-prem
// subnets that should be routable through the tunnel.
//
// Ref: https://learn.microsoft.com/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings#lng
// ---------------------------------------------------------------------------

resource localNetworkGateway 'Microsoft.Network/localNetworkGateways@2024-01-01' = {
  name: lgwName
  location: location
  tags: tags
  properties: {
    gatewayIpAddress: onPremVpnDeviceIp
    localNetworkAddressSpace: {
      addressPrefixes: onPremAddressSpaces
    }
  }
}

// ---------------------------------------------------------------------------
// S2S VPN Connection
//
// Ties the Azure VPN Gateway to the Local Network Gateway using IKEv2 + PSK.
// The shared key must match what's configured on the on-prem device.
//
// Ref: https://learn.microsoft.com/azure/vpn-gateway/vpn-gateway-howto-site-to-site-resource-manager-portal
// ---------------------------------------------------------------------------

resource vpnConnection 'Microsoft.Network/connections@2024-01-01' = {
  name: connectionName
  location: location
  tags: tags
  properties: {
    connectionType: 'IPsec'
    virtualNetworkGateway1: {
      id: vpnGateway.outputs.resourceId
      properties: {}
    }
    localNetworkGateway2: {
      id: localNetworkGateway.id
      properties: {}
    }
    sharedKey: vpnSharedKey
    enableBgp: false
    connectionProtocol: 'IKEv2'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output vnetId string = vnet.outputs.resourceId
output vnetName string = vnet.outputs.name
output privateEndpointSubnetId string = vnet.outputs.subnetResourceIds[1]
output vpnGatewayPublicIp string = vpnGwPip.properties.ipAddress
