# ACA Private Hub-and-Spoke Pattern (Bicep)

Deploys **Azure Container Apps on a private VNet using a dedicated workload profile** in a
**hub-and-spoke** topology, with all egress forced through an **Azure Firewall (Basic SKU)**.
The environment runs **four internal sample apps** (`app1`–`app4`), each resolvable at
`appN.customer.com` via **Azure Private DNS zones**. A separate **management spoke** hosts a
**Windows 11 test VM** (no public IP) that you reach over **RDP through a firewall DNAT rule**,
then use to browse the apps.

IaC is **Bicep only**.

## Topology

```
                          ┌────────────────────────────────┐
                          │  HUB  vnet-hub-<prefix>         │
        RDP (DNAT)        │  10.0.0.0/16                   │
   you ─────────────────▶ │  ┌──────────────────────────┐  │
   firewall PIP:3389      │  │ Azure Firewall (Basic)   │  │
                          │  │  AzureFirewallSubnet      │  │
                          │  │   10.0.0.0/26             │  │
                          │  │  AzureFirewallMgmtSubnet  │  │
                          │  │   10.0.1.0/26             │  │
                          │  │  DNAT :3389 -> 10.3.0.4   │  │
                          │  └───────┬──────────┬────────┘  │
                          └──────────┼──────────┼───────────┘
                          peering    │          │   peering
              ┌──────────────────────┘          └──────────────────────┐
   ┌──────────▼───────────────┐                          ┌─────────────▼────────────┐
   │ SPOKE 1  ACA             │                          │ SPOKE 2  MGMT            │
   │ vnet-spoke-aca-<prefix>  │                          │ vnet-spoke-mgmt-<prefix> │
   │ 10.1.0.0/16              │                          │ 10.3.0.0/16              │
   │  snet-aca 10.1.0.0/23    │                          │  snet-mgmt 10.3.0.0/24   │
   │   (Microsoft.App deleg.) │                          │   Windows 11 VM 10.3.0.4 │
   │  snet-pe  10.1.2.0/24    │                          │   (no public IP)         │
   │  Internal ACA env        │                          └──────────────────────────┘
   │   app1 app2 app3 app4    │
   └──────────────────────────┘

   Azure Private DNS zones (global, linked to hub + ACA spoke + mgmt spoke):
     • customer.com               A app1..app4  -> ACA env static IP (host-based routing)
     • <acaEnv.defaultDomain>     A *           -> ACA env static IP
```

## What gets deployed

| Resource | Purpose |
|----------|---------|
| Log Analytics Workspace | ACA environment logs |
| **Hub VNet** `10.0.0.0/16` | Hosts the firewall |
| `AzureFirewallSubnet` `10.0.0.0/26` | Firewall data plane (name is fixed by Azure) |
| `AzureFirewallManagementSubnet` `10.0.1.0/26` | **Required** for the Basic SKU management plane |
| **Azure Firewall (Basic)** + data PIP + mgmt PIP + Firewall Policy (Basic tier) | Central egress + **RDP DNAT** |
| **ACA spoke VNet** `10.1.0.0/16` | `snet-aca` (delegated) + `snet-pe`; DNS = Azure default; UDR -> firewall |
| ACA Managed Environment | `internal = true`, `publicNetworkAccess = Disabled`, dedicated D4 profile |
| **4 Container Apps** `app1`–`app4` | Internal ingress only, on the dedicated profile |
| **MGMT spoke VNet** `10.3.0.0/16` | `snet-mgmt`; UDR -> firewall |
| **Windows 11 VM** `vm-win11-test` | `Standard_D2s_v5`, Premium SSD, static `10.3.0.4`, **no public IP** |
| **Azure Private DNS zone `customer.com`** | `app1..app4` -> ACA env static IP; linked to all 3 VNets |
| **Azure Private DNS zone (ACA default domain)** | Wildcard `*.<defaultDomain>` -> env static IP; linked to all 3 VNets |
| Bidirectional peerings | hub<->spoke-aca and hub<->spoke-mgmt (`allowForwardedTraffic = true`) |

## The four sample apps

All four apps run in the **same internal ACA environment** on the dedicated workload profile.
Internal apps in one environment **share the environment's static IP**, so:

- Each app has its own `appN.customer.com` A-record pointing at that shared static IP.
- The ACA ingress routes the request to the correct app by **Host header**, so
  `http://app1.customer.com` … `http://app4.customer.com` each hit their own app.
- An `APP_NAME` env var is injected so you can tell the quickstart containers apart.

## RDP access via firewall DNAT

The Windows 11 VM has **no public IP**. RDP is published through an Azure Firewall **DNAT rule**:

```
firewall data public IP : 3389   ──DNAT──▶   10.3.0.4 : 3389 (Windows 11 VM)
```

- Source is open (`*`) — the VM is only ever reachable through this DNAT, never directly.
- After deploy, grab the firewall public IP from the `firewallPublicIp` / `rdpConnect` output and
  RDP to `<firewallPublicIp>:3389`.
- From inside the VM, browse `http://app1.customer.com` … `http://app4.customer.com`.

## Name resolution

No DNS server VM — resolution is entirely **Azure Private DNS**:

- The **`customer.com`** private zone holds `app1`–`app4` A-records → the ACA env static IP.
- The **ACA default-domain** private zone (`*.<defaultDomain>` → env static IP) resolves the
  auto-generated `*.azurecontainerapps.io` internal endpoints.
- Both zones are **linked to every VNet** (hub + ACA spoke + mgmt spoke), so any workload using
  default Azure DNS (`168.63.129.16`) — including the Windows 11 VM — resolves them automatically.

## Routing

Each spoke subnet carries a UDR:

- `0.0.0.0/0` → **VirtualAppliance** (firewall private IP) — all egress via the firewall
- `168.63.129.16/32` → **Internet** — keep Azure platform DNS / WireServer direct

## Firewall rules — INTENTIONALLY BROAD (lab)

The Firewall Policy (Basic tier) ships permissive so the lab "just works":

- **NAT rule:** DNAT `TCP/3389` on the firewall data PIP → `10.3.0.4:3389` (Windows 11 RDP).
- **Application rule:** allow `http:80` + `https:443` to `*` from `10.0.0.0/8`.
- **Network rules:** allow all TCP/UDP/ICMP within `10.0.0.0/8`, explicit **DNS 53** allow, and
  broad `10.0.0.0/8` → `*` egress.

> ⚠️ **These rules are deliberately wide open for a lab. Tighten `sourceAddresses` on the DNAT
> rule (e.g. to your office IP), `targetFqdns`, and ports before any real / shared / production use.**

## Deploy

```bash
export WIN11_ADMIN_PASSWORD='<StrongP@ssw0rd!>'
./deploy.sh rg-aca-hubspoke australiaeast
```

Or manually:

```bash
az group create -n rg-aca-hubspoke -l australiaeast
az deployment group create \
  -g rg-aca-hubspoke \
  -f main.bicep \
  -p @main.bicepparam \
  -p adminPassword='<StrongP@ssw0rd!>'
```

## Structure

| File | Role |
|------|------|
| `main.bicep` | Everything: hub + firewall (+ DNAT) + ACA spoke (4 apps) + mgmt spoke (Win11 VM) + UDRs + peerings + LAW + `customer.com` zone + outputs |
| `modules/dns.bicep` | ACA default-domain Azure Private DNS zone (wildcard), linked to all 3 VNets |
| `main.bicepparam` | Default parameter values (VM password from `WIN11_ADMIN_PASSWORD` env var) |
| `deploy.sh` | Convenience RG-create + deploy wrapper |

## Parameters

See `main.bicepparam`. Key ones:

- `namePrefix` — prefix for all resource names
- `appNames` — the sample apps + their `customer.com` records (default `app1`–`app4`)
- `hubAddressSpace` / `acaSpokeAddressSpace` / `mgmtSpokeAddressSpace` + subnet prefixes
- `win11PrivateIp` — Windows 11 VM static IP (DNAT target, default `10.3.0.4`)
- `win11VmSize` / `win11ImageSku` — VM size + Windows 11 image
- `workloadProfileType` — dedicated profile (default `D4`)
- `customerDomain` — the emulated customer zone (default `customer.com`)
- `adminUsername` / `adminPassword` (@secure) — Windows 11 VM login

## Everything is private (except the firewall + published RDP)

- ACA environment is **internal** with `publicNetworkAccess = Disabled`.
- All four container apps use **`external: false`** ingress.
- Windows 11 VM has **no public IP** — reachable only via the firewall DNAT.
- The only public surface is the firewall's data/mgmt PIPs (mgmt required by the Basic SKU).
