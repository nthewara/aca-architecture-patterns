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

// Dedicated workload profile (the app runs here, not on Consumption)
param workloadProfileName = 'dedicated'
param workloadProfileType = 'D4'
param workloadMinCount = 1
param workloadMaxCount = 3

// Container app
param appName = 'app1'
param containerImage = 'mcr.microsoft.com/k8se/quickstart:latest'
param targetPort = 80
param cpu = '0.5'
param memory = '1Gi'

// Emulated customer DNS -> app1.customer.com (served by Azure Private DNS zone)
param customerDomain = 'customer.com'
param customerRecordName = 'app1'
