// main.bicep — azd entry point (subscription scope).
// azd always passes `environmentName` + `location`; it also injects any params
// that match AZURE_* env vars (here: adminPassword via the parameters file).
targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('azd environment name — used to derive the resource group + name prefix.')
param environmentName string

@minLength(1)
@description('Primary location for all resources.')
param location string

@description('Windows 11 VM admin username.')
param adminUsername string = 'azureadmin'

@secure()
@description('Windows 11 VM admin password. Supplied by azd from the env (WIN11_ADMIN_PASSWORD -> adminPassword).')
param adminPassword string

@description('Enable the ACA env custom DNS suffix + wildcard TLS from Key Vault. The wildcard cert must be imported into the vault as a separate cert-prep step (see README).')
param enableCustomDnsSuffix bool = false

var namePrefix = 'aca${take(uniqueString(subscription().id, environmentName), 8)}'

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: {
    'azd-env-name': environmentName
  }
}

module resources 'resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    location: location
    namePrefix: namePrefix
    adminUsername: adminUsername
    adminPassword: adminPassword
    enableCustomDnsSuffix: enableCustomDnsSuffix
  }
}

// azd wires these AZURE_* outputs back into the environment so `azd deploy`
// can push images to the registry.
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = resources.outputs.acrLoginServer
output AZURE_CONTAINER_REGISTRY_NAME string = resources.outputs.acrName
output AZURE_RESOURCE_GROUP string = rg.name

// Handy operator outputs.
output FIREWALL_PUBLIC_IP string = resources.outputs.firewallPublicIp
output RDP_CONNECT string = resources.outputs.rdpConnect
output APP_FQDNS array = resources.outputs.appFqdns
output CUSTOM_DNS_SUFFIX string = resources.outputs.customDnsSuffix
output KEY_VAULT_NAME string = resources.outputs.keyVaultName
