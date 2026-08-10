// main.bicep — Hub-and-spoke ACA private pattern (SINGLE FILE + one tiny DNS module).
//
//   HUB           vnet-hub-<prefix>         10.0.0.0/16  (Azure Firewall Basic)
//   SPOKE 1 ACA   vnet-spoke-aca-<prefix>   10.1.0.0/16  (internal ACA env + app1..app4)
//   SPOKE 2 MGMT  vnet-spoke-mgmt-<prefix>  10.3.0.0/16  (Windows 11 test/jump VM)
//
// FOUR internal sample apps run in one ACA environment. Internal apps in a single env
// share the env static IP; each app has its own internal ingress and is reachable by
// its own host (appN.customer.com), with the ACA ingress routing by Host header.
//
// Name resolution uses AZURE PRIVATE DNS ZONES (no DNS server VM):
//   * customer.com            — A app1..app4 -> ACA env static IP (host-based routing)
//   * <acaEnv.defaultDomain>  — wildcard -> ACA env static IP
// Both zones are linked to EVERY VNet (hub + ACA spoke + mgmt spoke), so Azure
// platform DNS (168.63.129.16) resolves them for any workload in the topology.
//
// Spoke egress is forced through the hub firewall via UDRs. The Windows 11 VM in the
// mgmt spoke has NO public IP; RDP is published through an Azure Firewall DNAT rule
// (firewall data public IP :3389 -> VM 10.3.0.4:3389).
targetScope = 'resourceGroup'

// ===========================================================================
// Parameters
// ===========================================================================
@description('Location for all resources.')
param location string = resourceGroup().location

@description('Short name prefix for resources.')
param namePrefix string = 'acapriv'

@description('Globally-unique ACR name (5-50 alphanumeric). azd pushes app images here.')
param acrName string = 'acr${namePrefix}${uniqueString(resourceGroup().id)}'

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

// --- MGMT spoke networking ---
@description('Management spoke VNet address space (Windows 11 test VM).')
param mgmtSpokeAddressSpace string = '10.3.0.0/16'

@description('Management subnet prefix.')
param mgmtSubnetPrefix string = '10.3.0.0/24'

@description('Static private IP for the Windows 11 VM.')
param win11PrivateIp string = '10.3.0.4'

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

// --- Sample container apps ---
@description('Names of the sample apps. Each becomes an app + appN.customer.com record.')
param appNames array = [
  'app1'
  'app2'
  'app3'
  'app4'
]

@description('Container image used for every sample app.')
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

// --- Custom DNS suffix + wildcard TLS (Key Vault) ---
@description('Enable the ACA env custom DNS suffix + wildcard TLS from Key Vault. Requires the wildcard cert to already be imported into the vault (see README cert-prep step).')
param enableCustomDnsSuffix bool = false

@description('Globally-unique Key Vault name (RBAC) that holds the wildcard cert.')
param keyVaultName string = 'kv${namePrefix}${take(uniqueString(resourceGroup().id), 8)}'

@description('Certificate/secret name for the wildcard cert inside the vault.')
param wildcardCertName string = 'wildcard-customer-com'

// --- Windows 11 test VM ---
@description('Windows 11 VM name (<= 15 chars for computerName).')
@maxLength(15)
param win11VmName string = 'vm-win11-test'

@description('Windows 11 VM size.')
param win11VmSize string = 'Standard_D2s_v5'

@description('Windows 11 VM admin username.')
param adminUsername string = 'azureadmin'

@description('Windows 11 VM admin password.')
@secure()
param adminPassword string

@description('Windows 11 marketplace image SKU (e.g. win11-23h2-pro, win11-24h2-pro).')
param win11ImageSku string = 'win11-24h2-pro'

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
//   * a DNAT rule publishes RDP (3389) to the Windows 11 VM
// Tighten targetFqdns / destinationAddresses / ports before any real use.
resource fwRcg 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2023-11-01' = {
  parent: fwPolicy
  name: 'DefaultRuleCollectionGroup'
  properties: {
    priority: 200
    ruleCollections: [
      {
        // DNAT: publish RDP to the Windows 11 test VM via the firewall data PIP.
        ruleCollectionType: 'FirewallPolicyNatRuleCollection'
        name: 'dnat-rdp-win11'
        priority: 100
        action: {
          type: 'Dnat'
        }
        rules: [
          {
            ruleType: 'NatRule'
            name: 'rdp-to-win11'
            ipProtocols: [
              'TCP'
            ]
            // Open source (VM is only reachable through this DNAT, never directly).
            sourceAddresses: [
              '*'
            ]
            // Firewall data public IP address (translated destination is the VM).
            destinationAddresses: [
              dataPip.properties.ipAddress
            ]
            destinationPorts: [
              '3389'
            ]
            translatedAddress: win11PrivateIp
            translatedPort: '3389'
          }
        ]
      }
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
            // Intra-lab: allow everything between the private ranges (hub<->spokes, spoke<->spoke).
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
// Route tables — force spoke egress through the firewall.
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
    ]
  }
}

// MGMT spoke UDR: keep the DNAT return path symmetric.
//   Force default egress to the firewall BUT keep the AzureFirewallSubnet reachable
//   directly (168.63.129.16 direct as usual). This preserves the RDP DNAT return path
//   because inbound RDP arrives from the firewall's private IP inside the hub, which is
//   part of internalCidr and reachable via the peering, not the 0.0.0.0/0 route.
resource mgmtRouteTable 'Microsoft.Network/routeTables@2023-11-01' = {
  name: 'vnet-spoke-mgmt-${namePrefix}-rt'
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
// SPOKE 2 — MGMT (Windows 11 test VM)
//   snet-mgmt only. VNet DNS left default so the linked Private DNS zones resolve
//   appN.customer.com from the VM. Egress forced through the firewall via UDR.
// ===========================================================================
resource mgmtSpokeVnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'vnet-spoke-mgmt-${namePrefix}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        mgmtSpokeAddressSpace
      ]
    }
    subnets: [
      {
        name: 'snet-mgmt'
        properties: {
          addressPrefix: mgmtSubnetPrefix
          routeTable: {
            id: mgmtRouteTable.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// ===========================================================================
// PEERINGS — bidirectional hub<->spoke-aca and hub<->spoke-mgmt
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

resource peerHubToMgmt 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: hubVnet
  name: 'hub-to-spoke-mgmt'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: mgmtSpokeVnet.id
    }
  }
}

resource peerMgmtToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: mgmtSpokeVnet
  name: 'spoke-mgmt-to-hub'
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
// ACA managed environment (internal) + FOUR container apps — in the ACA spoke
// ===========================================================================
// ===========================================================================
// Azure Container Registry (Standard) + user-assigned managed identity
//   KEYS-DISABLED TENANT: ACR admin user is OFF. The ACA apps pull images using
//   a USER-ASSIGNED managed identity granted AcrPull — no registry passwords.
//   azd builds + pushes the app images to this ACR, then updates each app.
// ===========================================================================
resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: acrName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource acaIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${namePrefix}-aca'
  location: location
}

// AcrPull for the user-assigned identity, scoped to the registry.
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, acaIdentity.id, 'AcrPull')
  scope: acr
  properties: {
    principalId: acaIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    // AcrPull built-in role.
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
  }
}

// ===========================================================================
// Key Vault (RBAC) for the wildcard TLS certificate  [optional]
//   The ACA env pulls the *.<customerDomain> cert from here via the user-assigned
//   MI to serve the custom DNS suffix over TLS. KEYS-DISABLED TENANT: RBAC only,
//   no access policies; the MI gets Secrets User + Certificate User.
//   NOTE: Bicep cannot generate a PFX. Import the wildcard cert into this vault
//   BEFORE (or out-of-band from) this deployment — see the README cert-prep step.
// ===========================================================================
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = if (enableCustomDnsSuffix) {
  name: keyVaultName
  location: location
  tags: {
    // Survive the tenant policy that auto-disables public network access.
    SecurityControl: 'Ignore'
  }
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    publicNetworkAccess: 'Enabled'
  }
}

// MI -> Key Vault Secrets User (read the cert secret for the TLS binding).
resource kvSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableCustomDnsSuffix) {
  name: guid(keyVault.id, acaIdentity.id, 'KeyVaultSecretsUser')
  scope: keyVault
  properties: {
    principalId: acaIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    // Key Vault Secrets User.
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
}

// MI -> Key Vault Certificate User.
resource kvCertUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (enableCustomDnsSuffix) {
  name: guid(keyVault.id, acaIdentity.id, 'KeyVaultCertificateUser')
  scope: keyVault
  properties: {
    principalId: acaIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    // Key Vault Certificate User.
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'db79e9a7-68ee-4b58-9aeb-b90e7c24fcba')
  }
}

var wildcardCertSecretUrl = enableCustomDnsSuffix ? '${keyVault!.properties.vaultUri}secrets/${wildcardCertName}' : ''

resource acaEnv 'Microsoft.App/managedEnvironments@2024-10-02-preview' = {
  name: 'cae-${namePrefix}'
  location: location
  // The env needs the user-assigned MI so it can read the wildcard cert from KV.
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${acaIdentity.id}': {}
    }
  }
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
    // Custom DNS suffix + wildcard TLS (optional). When enabled, the env serves
    // *.<customerDomain> using the cert pulled from Key Vault via the MI.
    customDomainConfiguration: enableCustomDnsSuffix ? {
      dnsSuffix: customerDomain
      certificateKeyVaultProperties: {
        identity: acaIdentity.id
        keyVaultUrl: wildcardCertSecretUrl
      }
    } : null
    zoneRedundant: false
    workloadProfiles: [
      // Consumption profile is always present as the default baseline.
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
      // The dedicated profile the apps actually run on.
      {
        name: workloadProfileName
        workloadProfileType: workloadProfileType
        minimumCount: workloadMinCount
        maximumCount: workloadMaxCount
      }
    ]
  }
  // Ensure the MI can read the KV cert before the env tries to bind it.
  dependsOn: enableCustomDnsSuffix ? [
    kvSecretsUser
    kvCertUser
  ] : []
}

// Four sample apps, each with internal ingress on the dedicated profile.
//   - identity: the user-assigned MI (for AcrPull image pulls, keys-disabled)
//   - registries: ACR via the MI (no admin password)
//   - tags: azd-service-name = <app> so `azd deploy` targets the right app
//   - image starts as a placeholder; azd builds + pushes the real image and
//     updates the container on `azd up`/`azd deploy`.
resource apps 'Microsoft.App/containerApps@2024-03-01' = [
  for name in appNames: {
    name: name
    location: location
    tags: {
      'azd-service-name': name
    }
    identity: {
      type: 'UserAssigned'
      userAssignedIdentities: {
        '${acaIdentity.id}': {}
      }
    }
    properties: {
      managedEnvironmentId: acaEnv.id
      workloadProfileName: workloadProfileName
      configuration: {
        activeRevisionsMode: 'Single'
        registries: [
          {
            server: acr.properties.loginServer
            identity: acaIdentity.id
          }
        ]
        ingress: {
          // Private: internal ingress only — reachable only inside the VNet mesh.
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
            name: name
            // Placeholder until azd builds + pushes the real image. azd updates
            // this to <acr>/<app>:<tag> on deploy. Kept as the quickstart image
            // so the app is reachable even before the first `azd deploy`.
            image: containerImage
            resources: {
              cpu: json(cpu)
              memory: memory
            }
            env: [
              {
                name: 'APP_NAME'
                value: name
              }
            ]
          }
        ]
        scale: {
          minReplicas: 1
          maxReplicas: 3
        }
      }
    }
  }
]

// ===========================================================================
// Azure PRIVATE DNS — customer.com "customer" zone
//   Authoritative for the emulated customer domain. One A record per sample app
//   (app1..app4) -> the shared ACA env static IP; ACA ingress routes by Host header.
//   Linked to EVERY VNet (hub + ACA spoke + mgmt spoke) so Azure platform DNS resolves it.
// ===========================================================================
resource customerZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: customerDomain
  location: 'global'
}

resource customerRecords 'Microsoft.Network/privateDnsZones/A@2020-06-01' = [
  for name in appNames: {
    parent: customerZone
    name: name
    properties: {
      ttl: 300
      aRecords: [
        {
          ipv4Address: acaEnv.properties.staticIp
        }
      ]
    }
  }
]

// Wildcard record for the custom DNS suffix: *.<customerDomain> -> env static IP.
//   This is what makes appN.<customerDomain> (and any other host) resolve to the
//   internal ingress when the custom DNS suffix + wildcard TLS are enabled.
resource wildcardRecord 'Microsoft.Network/privateDnsZones/A@2020-06-01' = if (enableCustomDnsSuffix) {
  parent: customerZone
  name: '*'
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

resource customerZoneLinkMgmt 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: customerZone
  name: 'link-spoke-mgmt'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: mgmtSpokeVnet.id
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
      mgmtSpokeVnet.id
    ]
  }
}

// ===========================================================================
// Windows 11 test VM — in the MGMT spoke. NO public IP.
//   RDP is reached ONLY through the firewall DNAT rule (dataPip:3389 -> VM:3389).
// ===========================================================================
resource win11Nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${win11VmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: mgmtSpokeVnet.properties.subnets[0].id
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: win11PrivateIp
          // No publicIPAddress — reachable only via the firewall DNAT rule.
        }
      }
    ]
  }
}

resource win11Vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: win11VmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: win11VmSize
    }
    osProfile: {
      computerName: win11VmName
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsDesktop'
        offer: 'windows-11'
        sku: win11ImageSku
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: win11Nic.id
        }
      ]
    }
  }
}

// ===========================================================================
// Outputs
// ===========================================================================
output firewallPrivateIp string = firewallPrivateIp
output firewallPublicIp string = dataPip.properties.ipAddress
output acrLoginServer string = acr.properties.loginServer
output acrName string = acr.name
output envDefaultDomain string = acaEnv.properties.defaultDomain
output envStaticIp string = acaEnv.properties.staticIp
output appFqdns array = [for name in appNames: '${name}.${customerDomain}']
output appInternalFqdns array = [for (name, i) in appNames: apps[i].properties.configuration.ingress.fqdn]
output keyVaultName string = enableCustomDnsSuffix ? keyVault!.name : ''
output keyVaultUri string = enableCustomDnsSuffix ? keyVault!.properties.vaultUri : ''
output customDnsSuffix string = enableCustomDnsSuffix ? customerDomain : ''
output wildcardHttpsExample string = enableCustomDnsSuffix ? 'https://app1.${customerDomain}' : ''
output win11PrivateIp string = win11PrivateIp
output rdpConnect string = 'Connect RDP to ${dataPip.properties.ipAddress}:3389 (DNAT -> ${win11PrivateIp}:3389). From the VM, browse http://app1.${customerDomain} .. http://app4.${customerDomain}.'
output note string = 'Four internal apps resolve via customer.com (linked to hub + ACA + mgmt spokes) to ACA env static IP ${acaEnv.properties.staticIp}. Windows 11 VM has no public IP; RDP is published through the Azure Firewall DNAT rule on ${dataPip.properties.ipAddress}:3389.'
