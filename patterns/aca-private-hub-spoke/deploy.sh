#!/usr/bin/env bash
# Deploy the ACA hub-and-spoke private pattern (hub firewall + ACA spoke + Azure Private DNS).
# Usage: ./deploy.sh <resource-group> [location]
set -euo pipefail

RG="${1:-rg-aca-hubspoke}"
LOCATION="${2:-australiaeast}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ">> Creating resource group ${RG} in ${LOCATION}"
az group create -n "${RG}" -l "${LOCATION}" -o none

echo ">> Deploying main.bicep (hub + ACA spoke + Azure Private DNS)"
az deployment group create \
  -g "${RG}" \
  -f "${SCRIPT_DIR}/main.bicep" \
  -p "${SCRIPT_DIR}/main.bicepparam" \
  -o table

echo ">> Done. Outputs:"
az deployment group show -g "${RG}" -n main --query properties.outputs -o json 2>/dev/null || true
