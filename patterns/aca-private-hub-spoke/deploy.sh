#!/usr/bin/env bash
# Deploy the ACA hub-and-spoke private pattern:
#   hub firewall + ACA spoke (4 internal apps) + mgmt spoke (Windows 11 VM) + Azure Private DNS.
# Usage: ./deploy.sh <resource-group> [location]
# Requires: env var WIN11_ADMIN_PASSWORD (Windows 11 VM admin password),
#           OR pass -p adminPassword=... yourself.
set -euo pipefail

RG="${1:-rg-aca-hubspoke}"
LOCATION="${2:-australiaeast}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${WIN11_ADMIN_PASSWORD:-}" ]]; then
  echo "!! Set WIN11_ADMIN_PASSWORD (Windows 11 VM admin password) before deploying." >&2
  echo "   export WIN11_ADMIN_PASSWORD='<StrongP@ssw0rd!>'" >&2
  exit 1
fi

echo ">> Creating resource group ${RG} in ${LOCATION}"
az group create -n "${RG}" -l "${LOCATION}" -o none

echo ">> Deploying main.bicep (hub + ACA spoke [4 apps] + mgmt spoke [Win11 VM] + Azure Private DNS)"
az deployment group create \
  -g "${RG}" \
  -f "${SCRIPT_DIR}/main.bicep" \
  -p "${SCRIPT_DIR}/main.bicepparam" \
  -p adminPassword="${WIN11_ADMIN_PASSWORD}" \
  -o table

echo ">> Done. Outputs (RDP target + app FQDNs):"
az deployment group show -g "${RG}" -n main --query properties.outputs -o json 2>/dev/null || true
