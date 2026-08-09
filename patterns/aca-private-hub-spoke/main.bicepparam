using 'main.bicep'

param location = 'australiaeast'
param namePrefix = 'acapriv'

// --- Hub networking ---
param hubAddressSpace = '10.0.0.0/16'
param firewallSubnetPrefix = '10.0.0.0/26'
param firewallMgmtSubnetPrefix = '10.0.1.0/26'

// --- ACA spoke networking ---
param acaSpokeAddressSpace = '10.1.0.0/16'
param acaSubnetPrefix = '10.1.0.0/23'
param peSubnetPrefix = '10.1.2.0/24'

// --- MGMT spoke networking (Windows 11 test VM) ---
param mgmtSpokeAddressSpace = '10.3.0.0/16'
param mgmtSubnetPrefix = '10.3.0.0/24'
param win11PrivateIp = '10.3.0.4'

// Dedicated workload profile (the apps run here, not on Consumption)
param workloadProfileName = 'dedicated'
param workloadProfileType = 'D4'
param workloadMinCount = 1
param workloadMaxCount = 3

// Four sample apps -> app1.customer.com .. app4.customer.com
param appNames = [
  'app1'
  'app2'
  'app3'
  'app4'
]
param containerImage = 'mcr.microsoft.com/k8se/quickstart:latest'
param targetPort = 80
param cpu = '0.5'
param memory = '1Gi'

// Emulated customer DNS zone (served by Azure Private DNS)
param customerDomain = 'customer.com'

// Windows 11 test VM (no public IP; RDP via firewall DNAT)
param win11VmName = 'vm-win11-test'
param win11VmSize = 'Standard_D2s_v5'
param win11ImageSku = 'win11-23h2-pro'
param adminUsername = 'azureadmin'
// SECURITY: supply adminPassword at deploy time, e.g.
//   az deployment group create ... -p adminPassword='<StrongP@ssw0rd!>'
// Do NOT commit a real password here.
param adminPassword = readEnvironmentVariable('WIN11_ADMIN_PASSWORD', '')
