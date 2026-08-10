# ACA Architecture Patterns

A collection of **production-style reference architectures for Azure Container Apps (ACA)**,
delivered as **Bicep**. Each pattern is self-contained, compiles clean, and is designed to be
deployed into a lab subscription to demonstrate a specific networking / security posture.

> IaC is **Bicep only**. Templates only — nothing is deployed by cloning this repo.

## Patterns

| Pattern | Summary |
|---------|---------|
| [`aca-private-hub-spoke`](patterns/aca-private-hub-spoke/) | Fully private ACA on a dedicated workload profile in a hub-and-spoke topology. Four internal sample apps (`app1`–`app4`) resolvable at `appN.customer.com` via Azure Private DNS. All egress forced through an Azure Firewall (Basic SKU). A management spoke hosts a Windows 11 test VM reachable over RDP through a firewall DNAT rule. |
| [`aca-private-hub-spoke-azd`](patterns/aca-private-hub-spoke-azd/) | Same topology, packaged for **Azure Developer CLI**. `azd up` provisions the infra **and** builds + deploys four real sample apps to the private ACA env. Adds ACR (Standard) + user-assigned managed identity with `AcrPull` for password-less image pulls (keys-disabled-tenant safe). |
| [`aca-private-default-domain-azd`](patterns/aca-private-default-domain-azd/) | Same private topology + 4 apps + Win11 mgmt VM, but **no custom DNS and no custom certificate**. Apps are reached over the environment's auto-generated `*.azurecontainerapps.io` names with the **platform-managed, publicly-trusted TLS cert** (free). Simplest fully-private variant — no Key Vault, no cert lifecycle. |

---

## Pattern: ACA Private Hub-and-Spoke

Azure Container Apps injected into a private VNet on a **dedicated workload profile**, internal
ingress only, `publicNetworkAccess = Disabled`. The environment runs **four internal sample apps**
(`app1`–`app4`), each resolvable at `appN.customer.com` via **Azure Private DNS zones**. A hub VNet
hosts an **Azure Firewall (Basic SKU)** and all spoke egress is forced through it via UDRs. A
separate **management spoke** hosts a **Windows 11 test VM** (no public IP) reached over **RDP
through a firewall DNAT rule**, which you then use to browse the apps.

### Architecture diagram

```mermaid
flowchart TB
    USER(["🧑‍💻 You"]) -->|"RDP to firewall PIP:3389 (DNAT)"| FW

    subgraph HUB["🛡️ HUB VNet — vnet-hub-&lt;prefix&gt; (10.0.0.0/16)"]
        FW["Azure Firewall (Basic)<br/>AzureFirewallSubnet 10.0.0.0/26<br/>AzureFirewallManagementSubnet 10.0.1.0/26<br/>data PIP + mgmt PIP<br/>DNAT :3389 → 10.3.0.4"]
    end

    subgraph SPOKE["📦 ACA SPOKE — vnet-spoke-aca-&lt;prefix&gt; (10.1.0.0/16)"]
        direction TB
        SNETACA["snet-aca 10.1.0.0/23<br/>(Microsoft.App/environments delegation)"]
        SNETPE["snet-pe 10.1.2.0/24"]
        ACAENV["ACA Managed Environment<br/>internal = true · publicNetworkAccess = Disabled<br/>dedicated D4 workload profile"]
        APPS["app1 · app2 · app3 · app4<br/>internal ingress only"]
        SNETACA --- ACAENV --- APPS
    end

    subgraph MGMT["🖥️ MGMT SPOKE — vnet-spoke-mgmt-&lt;prefix&gt; (10.3.0.0/16)"]
        WIN11["Windows 11 test VM<br/>snet-mgmt 10.3.0.0/24<br/>10.3.0.4 · no public IP"]
    end

    subgraph PDNS["🌐 Azure Private DNS (global · linked to all 3 VNets)"]
        Z1["customer.com<br/>app1..app4 → ACA static IP"]
        Z2["&lt;acaEnv.defaultDomain&gt;<br/>* → ACA static IP"]
    end

    HUB <-->|"peering (allowForwardedTraffic)"| SPOKE
    HUB <-->|"peering (allowForwardedTraffic)"| MGMT
    SPOKE -->|"0.0.0.0/0 UDR → firewall"| FW
    MGMT -->|"0.0.0.0/0 UDR → firewall"| FW
    FW -->|"egress"| INET(["Internet"])
    WIN11 -.->|"http://appN.customer.com"| APPS
    PDNS -.-> HUB
    PDNS -.-> SPOKE
    PDNS -.-> MGMT
```

<details>
<summary>ASCII fallback</summary>

```
                          +--------------------------------+
        RDP (DNAT)        |  HUB  vnet-hub-<prefix>        |
   you ----------------->  |  10.0.0.0/16                  |
   firewall PIP:3389      |  Azure Firewall (Basic)        |
                          |   DNAT :3389 -> 10.3.0.4       |
                          +------+------------------+------+
                          peering|                  |peering
              +------------------+                  +------------------+
   +----------v-------------+              +---------v----------------+
   | ACA SPOKE 10.1.0.0/16  |              | MGMT SPOKE 10.3.0.0/16   |
   |  snet-aca 10.1.0.0/23  |              |  snet-mgmt 10.3.0.0/24   |
   |  snet-pe  10.1.2.0/24  |              |  Windows 11 VM 10.3.0.4  |
   |  Internal ACA env      |              |   (no public IP)         |
   |   app1 app2 app3 app4  |              +--------------------------+
   +------------------------+

   Azure Private DNS zones (global, linked to hub + ACA spoke + mgmt spoke):
     - customer.com               A app1..app4  -> ACA env static IP
     - <acaEnv.defaultDomain>     A *           -> ACA env static IP
```
</details>

### Name resolution

No DNS server VM — resolution is entirely **Azure Private DNS**:

- The **`customer.com`** private zone holds `app1`–`app4` A-records → the ACA env static IP.
- The **ACA default-domain** private zone (`*.<defaultDomain>` → env static IP) resolves the
  auto-generated `*.azurecontainerapps.io` internal endpoints.
- Both zones are **linked to every VNet** (hub + ACA spoke + mgmt spoke), so any workload using
  default Azure DNS (`168.63.129.16`) — including the Windows 11 VM — resolves them automatically.

### Everything is private (except the firewall + published RDP)

- ACA environment is **internal** with `publicNetworkAccess = Disabled`.
- All four container apps use **`external: false`** ingress.
- Windows 11 VM has **no public IP** — reachable only via the firewall DNAT.
- The only public surface is the firewall's data/mgmt PIPs (mgmt required by the Basic SKU).

### Deploy

```bash
cd patterns/aca-private-hub-spoke
./deploy.sh rg-aca-hubspoke australiaeast
```

Full details, routing, firewall rules, and parameters are in the
[pattern README](patterns/aca-private-hub-spoke/README.md).

---

## Pattern: ACA Private Hub-and-Spoke (azd)

[`aca-private-hub-spoke-azd`](patterns/aca-private-hub-spoke-azd/) — the same private topology,
packaged for **Azure Developer CLI**. One `azd up` provisions the infra **and** builds + deploys
four real sample apps (`src/app1`–`app4`) to the private ACA environment. Adds **ACR (Standard)** +
a **user-assigned managed identity with `AcrPull`** so images are pulled without registry passwords
(safe for the keys-disabled tenant). Optionally enables a **custom DNS suffix + wildcard TLS from
Key Vault** (`ENABLE_CUSTOM_DNS_SUFFIX=true`) so apps answer at `appN.customer.com` over HTTPS.

```bash
cd patterns/aca-private-hub-spoke-azd
azd env new aca-priv && azd env set AZURE_LOCATION australiaeast
export WIN11_ADMIN_PASSWORD="$(op read 'op://<vault>/<item>/password')"
azd up
```

See the [pattern README](patterns/aca-private-hub-spoke-azd/README.md).

---

## Pattern: ACA Private Default-Domain (azd, no custom DNS / no cert)

[`aca-private-default-domain-azd`](patterns/aca-private-default-domain-azd/) — same private
topology + 4 apps + Windows 11 mgmt VM, but **deliberately without custom DNS or a custom
certificate**. Apps are reached over the environment's **auto-generated
`appN.<envDefaultDomain>.azurecontainerapps.io`** names, which the ACA platform serves with a
**managed, publicly-trusted TLS certificate for free** — no browser warning, no cert lifecycle,
no Key Vault. A single private DNS zone for the default domain is linked to all three VNets so the
internal names resolve to the environment's private IP. This is the **simplest fully-private
variant**.

```bash
cd patterns/aca-private-default-domain-azd
azd env new aca-defdns && azd env set AZURE_LOCATION australiaeast
export WIN11_ADMIN_PASSWORD="$(op read 'op://<vault>/<item>/password')"
azd up
```

See the [pattern README](patterns/aca-private-default-domain-azd/README.md).

---

## Repo structure

```
aca-architecture-patterns/
├── README.md                              # this file
└── patterns/
    ├── aca-private-hub-spoke/             # Bicep-only, custom DNS + BIND-free wildcard cert
    │   ├── README.md
    │   ├── main.bicep                     # hub + firewall (+DNAT) + ACA spoke (4 apps) + mgmt spoke (Win11 VM) + customer.com zone
    │   ├── main.bicepparam
    │   ├── modules/dns.bicep              # ACA default-domain private zone (deferred name)
    │   └── deploy.sh
    ├── aca-private-hub-spoke-azd/         # azd: infra + app deploy, ACR + MI, optional custom DNS/TLS
    │   ├── README.md
    │   ├── azure.yaml                     # maps app1..app4 services -> container apps
    │   ├── infra/                         # main.bicep (sub-scope) + resources.bicep + modules + params
    │   ├── scripts/prep-wildcard-cert.sh  # one-time PFX generate + import (custom-DNS option)
    │   └── src/app1..app4/                # real sample apps (Dockerfile + server.js)
    └── aca-private-default-domain-azd/    # azd: NO custom DNS / NO cert, platform TLS on *.azurecontainerapps.io
        ├── README.md
        ├── azure.yaml
        ├── infra/                         # main.bicep (sub-scope) + resources.bicep + modules + params
        └── src/app1..app4/                # real sample apps (Dockerfile + server.js)
```

## Choosing a pattern

| If you want… | Use |
|---|---|
| Bicep-only, deploy with `az`/CI, friendly `customer.com` names | `aca-private-hub-spoke` |
| `azd up` to ship real apps, friendly `customer.com` names + your own wildcard cert | `aca-private-hub-spoke-azd` (with `ENABLE_CUSTOM_DNS_SUFFIX=true`) |
| `azd up`, simplest setup, trusted TLS out of the box, don't care about the long default URLs | `aca-private-default-domain-azd` |

All three keep everything **private**: internal ACA env, no public app IPs, reached from the
Windows 11 VM in the management spoke; the only public surface is the firewall.

## Contributing new patterns

Drop a new folder under `patterns/<name>/` with its own `README.md` and Bicep (plus `azure.yaml` +
`src/` if it's an azd pattern), then add a row to the **Patterns** table above. Keep templates
lab-safe: no committed secrets, `az bicep build` must pass clean.
