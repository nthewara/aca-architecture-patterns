// dns.bicep — Azure PRIVATE DNS zone for the ACA environment default domain ONLY.
//
// This lives in its own module because a private DNS zone `name` must be known at
// the start of the deployment; the ACA env `defaultDomain` is only known at runtime.
// Passing it as a module parameter defers evaluation, which is exactly what we need.
//
// The ACA default-domain zone (wildcard *.<defaultDomain> -> env static IP) is linked
// to EVERY VNet passed in (hub + ACA spoke) so Azure platform DNS (168.63.129.16)
// resolves the internal ACA endpoints from any workload in the topology.
@description('ACA environment auto-generated default domain, e.g. bluecoast-xxxx.australiaeast.azurecontainerapps.io')
param envDefaultDomain string

@description('ACA environment static internal IP.')
param envStaticIp string

@description('VNet resource ids to link the zone to (hub + spokes).')
param vnetIds array

resource acaZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: envDefaultDomain
  location: 'global'
}

resource acaWildcard 'Microsoft.Network/privateDnsZones/A@2020-06-01' = {
  parent: acaZone
  name: '*'
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: envStaticIp
      }
    ]
  }
}

resource acaZoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [
  for (vnetId, i) in vnetIds: {
    parent: acaZone
    name: 'aca-link-${i}'
    location: 'global'
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: vnetId
      }
    }
  }
]

output acaZoneName string = acaZone.name
