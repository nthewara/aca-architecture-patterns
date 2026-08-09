// main.bicep — Hub-and-spoke ACA private pattern (SINGLE FILE + one tiny DNS module).
//
//   HUB          vnet-hub-<prefix>        10.0.0.0/16  (Azure Firewall Basic)
//   SPOKE 1 ACA  vnet-spoke-aca-<prefix>  10.1.0.0/16  (internal ACA env + app1)
//
// Name resolution is done with AZURE PRIVATE DNS ZONES (no BIND VM):
//   * customer.com               — authoritative "customer" zone, A app1 -> ACA static IP
//   * <acaEnv.defaultDomain>     — ACA default-domain zone, wildcard -> ACA static IP
// Both zones are linked to EVERY VNet (hub + ACA spoke), so Azure platform DNS
// (168.63.129.16) resolves them automatically for any workload in either VNet.
//
// Spoke egress + spoke-to-hub traffic is forced through the hub firewall via a UDR.
targetScope = 'resourceGroup'

// ===========================================================================
// Parameters
// ===========================================================================
@description('Location for all resources.')
param location string = resourceGroup().location

@description('Short name prefix for resources.')
param namePrefix string = 'acapriv'

// --- Hub networking ---
@description('Hub VNet address space.')
param hubAddressSpace string = '10.0.0.0/16'

@description('AzureFirewallSubnet prefix (>= /26). Name is fixed by Azure.')
param firewallSubnetPrefix string = '10.0.0.0/26'

@description('AzureFirewallManagementSubnet prefix (>= /26, required for Basic SKU).')
param firewallMgmtSubnetPrefix string = '10.0.1.0/26'

// --- ACA spoke networking ---
@description('ACA spoke VNet address space.')
param acaSpokeAddressSpace string = '10.1.0.0/16'

@description('ACA infra subnet prefix (>= /23 for workload profiles).')
param acaSubnetPrefix string = '10.1.0.0/23'

@description('Private endpoint / utility subnet prefix.')
param peSubnetPrefix string = '10.1.2.0/24'

@description('Address space(s) considered "internal" for the lab firewall rules.')
param internalCidr string = '10.0.0.0/8'

// --- Dedicated workload profile ---
@description('Dedicated workload profile name.')
param workloadProfileName string = 'dedicated'

@description('Dedicated workload profile type (D4, D8, E4, ...).')
param workloadProfileType string = 'D4'

@description('Min nodes for the dedicated profile.')
param workloadMinCount int = 1

@description('Max nodes for the dedicated profile.')
param workloadMaxCount int = 3

// --- Container app ---
@description('Container app name / customer record host (app1 -> app1.customer.com).')
param appName string = 'app1'

@description('Container image.')
param containerImage string = 'mcr.microsoft.com/k8se/quickstart:latest'

@description('Container target port.')
param targetPort int = 80

@description('Container CPU cores.')
param cpu string = '0.5'

@description('Container memory.')
param memory string = '1Gi'

// --- Customer DNS emulation (served by Azure Private DNS) ---
@description('Emulated customer domain (Azure Private DNS zone).')
param customerDomain string = 'customer.com'

@description('Customer A record host label.')
param customerRecordName string = 'app1'

@description('Log Analytics retention in days.')
param lawRetentionInDays int = 30

// ===========================================================================
// Log Analytics
// ===========================================================================
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-${namePrefix}'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: lawRetentionInDays
  }
}

// ===========================================================================
// HUB VNet — AzureFirewallSubnet + AzureFirewallManagementSubnet (Basic SKU needs both)
// ===========================================================================
resource hubVnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'vnet-hub-${namePrefix}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        hubAddressSpace
      ]
    }
    subnets: [
      {
        // Name MUST be exactly AzureFirewallSubnet.
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: firewallSubnetPrefix
        }
      }
      {
        // Name MUST be exactly AzureFirewallManagementSubnet (Basic SKU requirement).
        name: 'AzureFirewallManagementSubnet'
        properties: {
          addressPrefix: firewallMgmtSubnetPrefix
        }
      }
    ]
  }
}

// ===========================================================================
// Azure Firewall BASIC SKU + Firewall Policy (Basic tier)
//   Basic REQUIRES: data PIP (Standard/Static) + management PIP (Standard/Static)
//   + management ipConfiguration pointing at AzureFirewallManagementSubnet.
//   Rules are intentionally BROAD for a lab — tighten for prod.
// ===========================================================================
resource dataPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'afw-${namePrefix}-pip-data'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource mgmtPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'afw-${namePrefix}-pip-mgmt'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource fwPolicy 'Microsoft.Network/firewallPolicies@2023-11-01' = {
  name: 'afwp-${namePrefix}'
  location: location
  properties: {
    sku: {
      tier: 'Basic'
    }
    threatIntelMode: 'Alert'
  }
}

// Rule collection group — INTENTIONALLY PERMISSIVE for a lab so that:
//   * ACA can still pull container images over http/https
//   * intra-lab traffic (routed via the firewall) is allowed
//   * DNS (53) is explicitly permitted for Azure platform DNS
// Tighten targetFqdns / destinationAddresses / ports before any real use.
resource fwRcg 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-11-01' = {
  parent: fwPolicy
  name: 'DefaultRuleCollectionGroup'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'app-allow-web'
        priority: 300
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'ApplicationRule'
            name: 'allow-all-web'
            protocols: [
              {
                protocolType: 'Http'
                port: 80
              }
              {
                protocolType: 'Https'
                port: 443
              }
            ]
            sourceAddresses: [
              internalCidr
            ]
            targetFqdns: [
              '*'
            ]
          }
        ]
      }
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'net-allow-lab'
        priority: 400
        action: {
          type: 'Allow'
        }
        rules: [
          {
            // Intra-lab: allow everything between the private ranges (hub<->spoke).
            ruleType: 'NetworkRule'
            name: 'allow-intra-vnet'
            ipProtocols: [
              'TCP'
              'UDP'
              'ICMP'
            ]
            sourceAddresses: [
              internalCidr
            ]
            destinationAddresses: [
              internalCidr
            ]
            destinationPorts: [
              '*'
            ]
          }
          {
            // DNS explicitly (workloads -> Azure platform DNS).
            ruleType: 'NetworkRule'
            name: 'allow-dns'
            ipProtocols: [
              'UDP'
              'TCP'
            ]
            sourceAddresses: [
              internalCidr
            ]
            destinationAddresses: [
              '*'
            ]
            destinationPorts: [
              '53'
            ]
          }
          {
            // General egress for the lab.
            ruleType: 'NetworkRule'
            name: 'allow-egress'
            ipProtocols: [
              'TCP'
              'UDP'
            ]
            sourceAddresses: [
              internalCidr
            ]
            destinationAddresses: [
              '*'
            ]
            destinationPorts: [
              '*'
            ]
          }
        ]
      }
    ]
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2023-11-01' = {
  name: 'afw-${namePrefix}'
  location: location
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Basic'
    }
    firewallPolicy: {
      id: fwPolicy.id
    }
    ipConfigurations: [
      {
        name: 'fw-ipconfig-data'
        properties: {
          subnet: {
            id: hubVnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: dataPip.id
          }
        }
      }
    ]
    // Management ipConfiguration is MANDATORY for the Basic SKU.
    managementIpConfiguration: {
      name: 'fw-ipconfig-mgmt'
      properties: {
        subnet: {
          id: hubVnet.properties.subnets[1].id
        }
        publicIPAddress: {
          id: mgmtPip.id
        }
      }
    }
  }
  dependsOn: [
    fwRcg
  ]
}

var firewallPrivateIp = firewall.properties.ipConfigurations[0].properties.privateIPAddress

// ===========================================================================
// Route table — force ACA spoke egress through the firewall.
//   0.0.0.0/0        -> VirtualAppliance (firewall private IP)
//   168.63.129.16/32 -> Internet (keep Azure platform DNS / WireServer direct)
// ===========================================================================
resource acaRouteTable 'Microsoft.Network/routeTables@2023-11-01' = {
  name: 'vnet-spoke-aca-${namePrefix}-rt'
  location: location
  properties: {
    disableBgpRoutePropagation: true
    routes: [
      {
        name: 'default-to-firewall'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }
      {
        name: 'azure-platform-dns-direct'
        properties: {
          addressPrefix: '168.63.129.16/32'
          nextHopType: 'Internet'
        }
      }
    ]
  }
}

// ===========================================================================
// SPOKE 1 — ACA
//   snet-aca (delegated to Microsoft.App/environments) + snet-pe
//   VNet DNS is LEFT DEFAULT (Azure 168.63.129.16) — the linked Private DNS zones
//   resolve customer.com + the ACA default domain automatically. Both subnets
//   carry the firewall UDR.
// ===========================================================================
resource acaSpokeVnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'vnet-spoke-aca-${namePrefix}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        acaSpokeAddressSpace
      ]
    }
    subnets: [
      {
        name: 'snet-aca'
        properties: {
          addressPrefix: acaSubnetPrefix
          delegations: [
            {
              name: 'aca-delegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          routeTable: {
            id: acaRouteTable.id
          }
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
      {
        name: 'snet-pe'
        properties: {
          addressPrefix: peSubnetPrefix
          routeTable: {
            id: acaRouteTable.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// ===========================================================================
// PEERINGS — bidirectional hub<->spoke-aca
//   allowForwardedTraffic: true so hub firewall transit works.
// ===========================================================================
resource peerHubToAca 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: hubVnet
  name: 'hub-to-spoke-aca'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: acaSpokeVnet.id
    }
  }
}

resource peerAcaToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: acaSpokeVnet
  name: 'spoke-aca-to-hub'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: hubVnet.id
    }
  }
}

// ===========================================================================
// ACA managed environment (internal) + container app — in the ACA spoke
// ===========================================================================
resource acaEnv 'Microsoft.App/managedEnvironments@2024-10-02-preview' = {
  name: 'cae-${namePrefix}'
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      // Private: inject into the VNet and make the environment internal-only.
      internal: true
      infrastructureSubnetId: acaSpokeVnet.properties.subnets[0].id
    }
    // Private: no public control/data plane access.
    publicNetworkAccess: 'Disabled'
    zoneRedundant: false
    workloadProfiles: [
      // Consumption profile is always present as the default baseline.
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
      // The dedicated profile the app actually runs on.
      {
        name: workloadProfileName
        workloadProfileType: workloadProfileType
        minimumCount: workloadMinCount
        maximumCount: workloadMaxCount
      }
    ]
  }
}

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  properties: {
    managedEnvironmentId: acaEnv.id
    // Run on the dedicated workload profile, not Consumption.
    workloadProfileName: workloadProfileName
    configuration: {
      ingress: {
        // Private: internal ingress only — reachable only inside the VNet.
        external: false
        targetPort: targetPort
        transport: 'auto'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: appName
          image: containerImage
          resources: {
            cpu: json(cpu)
            memory: memory
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

// ===========================================================================
// Azure PRIVATE DNS — customer.com "customer" zone
//   Authoritative for the emulated customer domain. A app1 -> ACA env static IP.
//   Linked to EVERY VNet (hub + ACA spoke) so Azure platform DNS resolves it.
//   The record name is a static value, so this can live inline in main.bicep.
// ===========================================================================
resource customerZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: customerDomain
  location: 'global'
}

resource customerRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: customerZone
  name: customerRecordName
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: acaEnv.properties.staticIp
      }
    ]
  }
}

resource customerZoneLinkHub 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: customerZone
  name: 'link-hub'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: hubVnet.id
    }
  }
}

resource customerZoneLinkAca 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: customerZone
  name: 'link-spoke-aca'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: acaSpokeVnet.id
    }
  }
}

// ===========================================================================
// Azure PRIVATE DNS — ACA default-domain zone linked to every VNet
//   Kept in a small module because a private DNS zone name must be known at the
//   start of the deployment, but acaEnv.defaultDomain is a runtime value.
//   Passing it as a module parameter defers evaluation (avoids BCP120).
// ===========================================================================
module dns 'modules/dns.bicep' = {
  name: 'aca-default-domain-dns'
  params: {
    envDefaultDomain: acaEnv.properties.defaultDomain
    envStaticIp: acaEnv.properties.staticIp
    vnetIds: [
      hubVnet.id
      acaSpokeVnet.id
    ]
  }
}

// ===========================================================================
// Outputs
// ===========================================================================
output firewallPrivateIp string = firewallPrivateIp
output envDefaultDomain string = acaEnv.properties.defaultDomain
output envStaticIp string = acaEnv.properties.staticIp
output appInternalFqdn string = app.properties.configuration.ingress.fqdn
output customerFqdn string = '${customerRecordName}.${customerDomain}'
output note string = 'Hub-and-spoke. ${customerRecordName}.${customerDomain} resolves via the Azure Private DNS zone (linked to hub + ACA spoke) to the ACA env static IP ${acaEnv.properties.staticIp}. Spoke egress transits the Azure Firewall (${firewallPrivateIp}).'
