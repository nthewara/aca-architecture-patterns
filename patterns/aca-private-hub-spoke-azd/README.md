# ACA Private Hub-and-Spoke — azd Variant (Infra + App Deployment)

Same private hub-and-spoke topology as [`aca-private-hub-spoke`](../aca-private-hub-spoke/), but
packaged for **Azure Developer CLI (`azd`)** so a single `azd up` **provisions the infrastructure
AND builds + deploys the four container apps**.

This variant adds what a real app-deployment flow needs (and the pure-infra pattern deliberately
omits):

- **Four real sample apps** (`src/app1`–`src/app4`) — tiny zero-dependency Node servers, each with
  a distinct landing page so host-based routing is visibly working.
- **Azure Container Registry (Standard)** — azd builds each Docker image and pushes it here.
- **User-assigned managed identity + `AcrPull`** — the ACA apps pull images via MI, **no registry
  passwords**. This matches the tenant policy where **service keys / admin creds are disabled**
  (ACR `adminUserEnabled = false`).

Everything else — internal ACA env, dedicated D4 profile, Azure Firewall (Basic), the four
`appN.customer.com` Private DNS records, the management spoke + Windows 11 VM, and the RDP DNAT
rule — is identical to the base pattern.

## Why azd here

- `azd up` = `provision` (Bicep) + `deploy` (build → push to ACR → update each container app).
- `azd deploy` afterwards is an app-only redeploy — no infra churn.
- `azd env` manages per-environment values (including the VM password) instead of hand-rolled
  env vars + bicepparam.

## Layout

```
aca-private-hub-spoke-azd/
├── azure.yaml                 # maps app1..app4 services -> container apps (azd-service-name tag)
├── infra/
│   ├── main.bicep             # azd entry point (subscription scope): RG + module
│   ├── main.parameters.json   # azd param bindings (env-substituted)
│   ├── resources.bicep        # all resources (hub + spokes + firewall + ACA + ACR + MI + DNS + VM)
│   └── modules/dns.bicep      # ACA default-domain private zone (deferred name)
└── src/
    ├── app1/ (server.js, Dockerfile)
    ├── app2/ ...
    ├── app3/ ...
    └── app4/ ...
```

## How the app mapping works

Each container app in `resources.bicep` is tagged `azd-service-name: <app>` and starts on a
**placeholder image** (the public quickstart) so it's reachable even before the first deploy.
`azure.yaml` maps `app1`–`app4` to those apps. On `azd deploy`, azd builds each `src/appN`
Dockerfile, pushes to ACR, and updates the matching container app to `<acr>/appN:<tag>`.

Because all four apps share the internal ACA environment's static IP, each `appN.customer.com`
A-record points at that IP and ACA routes by **Host header** — `http://app1.customer.com` …
`http://app4.customer.com` each hit their own app.

## Prerequisites

- `azd`, `az`, and Docker running locally
- Logged in: `az login` and `azd auth login`
- A strong Windows 11 VM password available (see below — **never commit it**)

## Deploy

```bash
cd patterns/aca-private-hub-spoke-azd

# 1. Create/select an azd environment
azd env new aca-priv        # or: azd env select aca-priv
azd env set AZURE_LOCATION australiaeast

# 2. Provide the Win11 VM password WITHOUT persisting it to the repo.
#    Option A — from 1Password at deploy time (nothing stored on disk):
export WIN11_ADMIN_PASSWORD="$(op read 'op://<vault>/<item>/password')"

#    Option B — export it yourself for this shell only:
#    export WIN11_ADMIN_PASSWORD='<StrongP@ssw0rd!>'

# 3. Provision infra + build/push/deploy all four apps
azd up
```

After `azd up`, grab the RDP target + app FQDNs:

```bash
azd env get-values | grep -E 'RDP_CONNECT|FIREWALL_PUBLIC_IP|APP_FQDNS'
```

RDP to `<FIREWALL_PUBLIC_IP>:3389` (published via the firewall DNAT), then from inside the
Windows 11 VM browse `http://app1.customer.com` … `http://app4.customer.com`.

Redeploy just the apps later:

```bash
azd deploy            # all four
azd deploy app2       # just app2
```

## Credential handling — nothing secret in the repo

- The VM password is **never** written to the repo. It flows in as the `WIN11_ADMIN_PASSWORD`
  environment variable (ideally sourced from 1Password with `op read`), which
  `main.parameters.json` binds to the `@secure()` `adminPassword` param.
- `azd` stores environment state under `.azure/` — that directory is **git-ignored** and must
  stay that way (it can contain resolved values). Do not commit it.
- ACR uses **no admin password**; image pulls are via managed identity + `AcrPull`.

## Network note (private ACR pull)

The ACA environment is internal, but ACR image pull for a **managed** ACA environment is handled
by the platform over the Microsoft backbone using the app's managed identity — no ACR private
endpoint is required for the pull itself. `azd`'s build step pushes from your workstation to the
ACR public login server (firewall-gated ACR can be added later; for this lab ACR public access is
enabled). If you harden ACR to private-only, run `azd deploy` from inside the network (e.g. the
Windows 11 VM or a build agent) so the push has a path.

## Relationship to the base pattern

| | `aca-private-hub-spoke` | `aca-private-hub-spoke-azd` (this) |
|---|---|---|
| Infra | ✅ Bicep | ✅ Bicep (same topology + ACR + MI) |
| Apps | quickstart placeholder | ✅ real `src/appN`, built + deployed by azd |
| Image pull | n/a | user-assigned MI + `AcrPull` (keys-disabled safe) |
| Deploy | `deploy.sh` / `az deployment` | `azd up` / `azd deploy` |

Use the base pattern to study the networking; use this variant to actually ship apps into it.
