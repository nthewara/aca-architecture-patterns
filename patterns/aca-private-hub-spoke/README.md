# ACA Hub-and-Spoke Private Pattern (Bicep)

Deploys **Azure Container Apps on a private VNet using a dedicated workload profile** in a
**hub-and-spoke** topology, with all egress forced through an **Azure Firewall (Basic SKU)**,
and **Azure Private DNS zones** providing name resolution for both the emulated customer
domain (`app1.customer.com`) and the ACA auto-generated default domain.

IaC is **Bicep only**.

## Topology

```
                        ┌──────────────────────────────┐
                        │  HUB  vnet-hub-<prefix>       │
                        │  10.0.0.0/16                  │
                        │  ┌────────────────────────┐   │
                        │  │ Azure Firewall (Basic) │   │
                        │  │  AzureFirewallSubnet    │   │
                        │  │   10.0.0.0/26           │   │
                        │  │  AzureFirewallMgmtSubnet│   │
                        │  │   10.0.1.0/26           │   │
                        │  └───────────┬────────────┘   │
                        └──────────────┴────────────────┘
                                       │  peering
                       ┌───────────────┘
            ┌──────────▼───────────────┐
            │ SPOKE 1  ACA             │
            │ vnet-spoke-aca-<prefix>  │
            │ 10.1.0.0/16              │
            │  snet-aca 10.1.0.0/23    │
            │   (Microsoft.App deleg.) │
            │  snet-pe  10.1.2.0/24    │
            │  DNS = Azure default     │
            │  Internal ACA env + app1 │
            └──────────────────────────┘

   Azure Private DNS zones (global, linked to hub + ACA spoke):
     • customer.com                 A app1  -> ACA env static IP
     • <acaEnv.defaultDomain>       A *     -> ACA env static IP
```

## What gets deployed

| Resource | Purpose |
|----------|---------|
| Log Analytics Workspace | ACA environment logs |
| **Hub VNet** `10.0.0.0/16` | Hosts the firewall |
| `AzureFirewallSubnet` `10.0.0.0/26` | Firewall data plane (name is fixed by Azure) |
| `AzureFirewallManagementSubnet` `10.0.1.0/26` | **Required** for the Basic SKU management plane |
| **Azure Firewall (Basic)** + data PIP + mgmt PIP + Firewall Policy (Basic tier) | Central egress inspection |
| **ACA spoke VNet** `10.1.0.0/16` | `snet-aca` (delegated) + `snet-pe`; DNS = Azure default; UDR -> firewall |
| ACA Managed Environment | `internal = true`, `publicNetworkAccess = Disabled`, dedicated D4 profile |
| Container App `app1` | Internal ingress only, on the dedicated profile |
| **Azure Private DNS zone `customer.com`** | `app1.customer.com` -> ACA env static IP; linked to hub + ACA spoke |
| **Azure Private DNS zone (ACA default domain)** | Wildcard `*.<defaultDomain>` -> env static IP; linked to hub + ACA spoke |
| Bidirectional peering | hub<->spoke-aca (`allowForwardedTraffic = true`) |

## How name resolution works

No DNS server VM — resolution is entirely **Azure Private DNS**:

- The **`customer.com`** private zone is authoritative for `app1.customer.com` → the ACA env static IP.
- The **ACA default-domain** private zone (`*.<defaultDomain>` → env static IP) resolves the
  auto-generated `*.azurecontainerapps.io` internal endpoints.
- Both zones are **linked to every VNet** (hub + ACA spoke), so any workload using the default
  Azure DNS (`168.63.129.16`) resolves them automatically — no custom VNet DNS servers needed.

## Routing

The ACA spoke subnets carry a UDR:

- `0.0.0.0/0` → **VirtualAppliance** (firewall private IP) — all egress via the firewall
- `168.63.129.16/32` → **Internet** — keep Azure platform DNS / WireServer direct (never through the firewall)

## Firewall rules — INTENTIONALLY BROAD (lab)

The Firewall Policy (Basic tier) ships permissive so the lab "just works":

- **Application rule:** allow `http:80` + `https:443` to `*` from `10.0.0.0/8` (lets ACA pull images, general web).
- **Network rules:** allow all TCP/UDP/ICMP between `10.0.0.0/8` ↔ `10.0.0.0/8`, explicit **DNS 53**
  allow, and broad `10.0.0.0/8` → `*` egress.

> ⚠️ **These rules are deliberately wide open for a lab. Tighten `targetFqdns`, `destinationAddresses`,
> and ports before any real / shared / production use.**

## Deploy

```bash
./deploy.sh rg-aca-hubspoke australiaeast
```

Or manually:

```bash
az group create -n rg-aca-hubspoke -l australiaeast
az deployment group create \
  -g rg-aca-hubspoke \
  -f main.bicep \
  -p @main.bicepparam
```

## Structure

Everything is defined in a **single `main.bicep`** — hub VNet, Azure Firewall (Basic) + policy,
ACA spoke, route table, peering, LAW, ACA env, container app, the `customer.com` Azure Private DNS
zone, and outputs.

The **one** exception is `modules/dns.bicep`, which holds the ACA default-domain Azure Private
DNS zone. A private DNS zone name must be known at the *start* of the deployment, but the ACA
environment's `defaultDomain` is only known at runtime — passing it as a module parameter defers
evaluation and avoids a `BCP120` compile error. That's the only reason it isn't inline.

| File | Role |
|------|------|
| `main.bicep` | Everything: hub + firewall + ACA spoke + UDR + peering + LAW + ACA env + app + `customer.com` zone + outputs |
| `modules/dns.bicep` | ACA default-domain Azure Private DNS zone (wildcard), linked to hub + ACA spoke |
| `main.bicepparam` | Default parameter values |
| `deploy.sh` | Convenience RG-create + deploy wrapper |

## Parameters

See `main.bicepparam`. Key ones:

- `namePrefix` — prefix for all resource names
- `hubAddressSpace` / `acaSpokeAddressSpace` + subnet prefixes
- `workloadProfileType` — dedicated profile (default `D4`)
- `customerDomain` / `customerRecordName` — the emulated customer record served by Azure Private DNS

## Everything is still private

- ACA environment is **internal** with `publicNetworkAccess = Disabled`.
- Container App ingress is **`external: false`**.
- No public IPs except the firewall's (data + mgmt), which are required by the Basic SKU.
- Reachable only from inside the VNet mesh (jump host / VPN / ER / peered network).
