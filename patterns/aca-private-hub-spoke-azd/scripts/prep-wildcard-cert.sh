#!/usr/bin/env bash
# prep-wildcard-cert.sh
# Generates a self-signed wildcard TLS cert for the ACA custom DNS suffix and
# imports it into the pattern's Key Vault, so `azd up` (with
# ENABLE_CUSTOM_DNS_SUFFIX=true) can bind it to the environment.
#
# Bicep can't generate a PFX, so this is a one-time out-of-band prep step. For
# production use a real CA-issued wildcard cert instead of the self-signed one.
#
# Usage:
#   ./scripts/prep-wildcard-cert.sh <key-vault-name> [domain] [cert-name]
#
# Example:
#   ./scripts/prep-wildcard-cert.sh kvacaXXXXXXXX customer.com wildcard-customer-com
set -euo pipefail

KV="${1:?key vault name required}"
DOMAIN="${2:-customer.com}"
CERT_NAME="${3:-wildcard-customer-com}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

PFX_PASS="$(openssl rand -base64 18)"

echo ">> Generating self-signed wildcard cert for *.${DOMAIN}"
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 825 \
  -subj "/CN=*.${DOMAIN}/O=ACA Lab/C=AU" \
  -addext "subjectAltName=DNS:*.${DOMAIN},DNS:${DOMAIN}"

openssl pkcs12 -export -out wildcard.pfx -inkey key.pem -in cert.pem -passout pass:"$PFX_PASS"

echo ">> Importing '${CERT_NAME}' into Key Vault '${KV}'"
az keyvault certificate import \
  --vault-name "$KV" \
  -n "$CERT_NAME" \
  -f wildcard.pfx \
  --password "$PFX_PASS" \
  --query "{id:id, thumbprint:x509ThumbprintHex}" -o json

echo ">> Done. The PFX password was random and is discarded with the temp dir."
echo ">> Now run:  ENABLE_CUSTOM_DNS_SUFFIX=true azd up   (or azd provision)"
