# ACA Private Default-Domain — azd Variant (No Custom DNS / No Custom Cert)

Same private hub-and-spoke topology as [`aca-private-hub-spoke-azd`](../aca-private-hub-spoke-azd/),
but **deliberately without any custom DNS or custom certificate**. The four apps are reached over
their **auto-generated `*.azurecontainerapps.io` default-domain names**, which the ACA platform
serves with a **managed, publicly-trusted TLS certificate for free**.

Everything stays **private** — the environment is internal, the apps have no public IP, and you
connect from the **Windows 11 VM** in the management spoke over private connectivity.

IaC is **Bicep only**; deployed with **Azure Developer CLI (`azd`)**.

## What's different from the custom-DNS variant

| | `aca-private-hub-spoke-azd` | `aca-private-default-domain-azd` (this) |
|---|---|---|
| App hostnames | `appN.customer.com` (custom suffix) | `appN.<envDefaultDomain>.azurecontainerapps.io` |
| TLS cert | wildcard `*.customer.com` you supply, stored in **Key Vault** | **platform-managed**, automatic, free |
| Key Vault | ✅ required (cert store) | ❌ none |
| Cert-prep step | ✅ generate + import PFX | ❌ none |
| `customer.com` private zone | ✅ | ❌ |
| Default-domain private zone | ✅ | ✅ (the only DNS) |
| Env managed identity | needed to read the KV cert | not needed for TLS (only apps use MI for ACR pull) |

**The trade-off:** simpler (no cert lifecycle, no Key Vault) and you get a *trusted* cert with no
browser warning — but the app URLs are the long auto-generated `*.azurecontainerapps.io` names
instead of a friendly `customer.com`.

## Topology

```
                          ┌────────────────────────────────┐
        RDP (DNAT)        │  HUB  vnet-hub-<prefix>         │
   you ───────────────▶   │  Azure Firewall (Basic)        │
   firewall PIP:3389      │   DNAT :3389 -> 10.3.0.4        │
                          └──────┬──────────────────┬──────┘
                          peering│                  │peering
              ┌──────────────────┘                  └──────────────────┐
   ┌──────────▼───────────────┐              ┌──────────────────────▼─────┐
   │ SPOKE 1  ACA             │              │ SPOKE 2  MGMT              │
   │ 10.1.0.0/16              │              │ 10.3.0.0/16                │
   │  Internal ACA env        │              │  Windows 11 VM 10.3.0.4    │
   │   app1 app2 app3 app4    │              │   (no public IP)           │
   └──────────────────────────┘              └────────────────────────────┘

   Azure Private DNS (linked to hub + ACA + mgmt spokes):
     • <envDefaultDomain>.azurecontainerapps.io   A *  -> ACA env static IP
```

## How name resolution + TLS works

- ACA assigns the environment a random default domain, e.g.
  `bluecoast-1234.australiaeast.azurecontainerapps.io`. Each app gets
  `app1.<that-domain>`, `app2.<that-domain>`, etc.
- Because the environment is **internal**, those names must resolve to the env's **private**
  static IP. A single **Azure Private DNS zone** named after the default domain (with a wildcard
  `*` A-record → env static IP) is linked to all three VNets, so the Windows 11 VM resolves them
  privately.
- TLS is **automatic**: the platform already holds a valid wildcard cert for
  `*.<envDefaultDomain>.azurecontainerapps.io`, so `https://app1.<domain>` is **trusted with no
  warning** — nothing for you to manage.

## What gets deployed

- Hub VNet + **Azure Firewall (Basic)** with an RDP **DNAT** rule (data PIP:3389 → 10.3.0.4)
- ACA spoke: internal ACA env (`publicNetworkAccess=Disabled`, dedicated D4 profile) + **app1–app4**
- Mgmt spoke: **Windows 11 VM** (`Standard_D2s_v5`, Premium SSD, static `10.3.0.4`, no public IP)
- **ACR (Standard)** + **user-assigned MI with `AcrPull`** for password-less image pulls
- **One Azure Private DNS zone** for the default domain, linked to all three VNets
- Bidirectional hub↔spoke peerings; UDRs forcing spoke egress through the firewall

No Key Vault, no certificate, no custom domain.

## Prerequisites

- `azd`, `az`, and Docker running locally
- `az login` and `azd auth login`
- A strong Windows 11 VM password available (never committed)

## Deploy

```bash
cd patterns/aca-private-default-domain-azd

azd env new aca-defdns
azd env set AZURE_LOCATION australiaeast

# Win11 VM password from 1Password (nothing persisted to disk):
export WIN11_ADMIN_PASSWORD="$(op read 'op://<vault>/<item>/password')"

azd up
```

After `azd up`, get the app URLs + RDP target:

```bash
azd env get-values | grep -E 'APP_FQDNS|RDP_CONNECT|FIREWALL_PUBLIC_IP'
```

RDP to `<FIREWALL_PUBLIC_IP>:3389`, then from inside the Windows 11 VM browse each app at its
`https://app1.<envDefaultDomain>.azurecontainerapps.io` URL (listed in `APP_FQDNS`). The cert is
platform-trusted, so no browser warning.

Redeploy apps later with `azd deploy` (all) or `azd deploy app2` (one).

## Everything is private

- ACA environment is **internal** (`publicNetworkAccess = Disabled`).
- Apps use **`external: true`** ingress — on an internal env this is **VNet-scoped, not
  internet-facing** (this is what lets the mgmt-spoke VM reach them; `external:false` would 404
  from a peered VNet).
- Windows 11 VM has **no public IP** — reachable only via the firewall DNAT.
- Only public surface is the firewall's data/mgmt PIPs (mgmt required by the Basic SKU).

## Credential handling — nothing secret in the repo

- The VM password flows in via `WIN11_ADMIN_PASSWORD` (bind to the `@secure()` `adminPassword`
  param), ideally from 1Password with `op read`. Never written to the repo.
- `.azure/` (azd env state) is git-ignored.
- ACR uses **no admin password**; image pulls are via managed identity + `AcrPull`.
