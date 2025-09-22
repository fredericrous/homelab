#!/bin/bash
# Bootstrap script to create the vault transit token secret
# This should be run once after cluster creation

set -euo pipefail

# Use provided token or load from environment
TRANSIT_TOKEN="${1:-${VAULT_TRANSIT_TOKEN:-}}"

# If not provided and not in environment, try .env file
if [ -z "$TRANSIT_TOKEN" ] && [ -f .env ]; then
  source .env
  TRANSIT_TOKEN="${VAULT_TRANSIT_TOKEN:-}"
fi

# Token must be provided
if [ -z "$TRANSIT_TOKEN" ]; then
  echo "ERROR: Transit token not provided"
  echo "Usage: $0 [transit-token]"
  echo "Or set VAULT_TRANSIT_TOKEN environment variable"
  echo "Or add VAULT_TRANSIT_TOKEN to .env file"
  exit 1
fi

echo "Creating vault-transit-token secret in vault namespace..."
kubectl create secret generic vault-transit-token \
  --namespace=vault \
  --from-literal=vault_transit_token="$TRANSIT_TOKEN" \
  --from-literal=token="$TRANSIT_TOKEN" \
  --dry-run=client -o yaml | \
kubectl annotate -f - \
  reflector.v1.k8s.emberstack.com/reflection-allowed="true" \
  reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces="flux-system" \
  reflector.v1.k8s.emberstack.com/reflection-auto-enabled="true" \
  --dry-run=client -o yaml | \
kubectl apply -f -

echo "Waiting for Reflector to copy secret to flux-system namespace..."
sleep 5

if kubectl get secret vault-transit-token -n flux-system &>/dev/null; then
  echo "✅ Secret successfully reflected to flux-system namespace"
else
  echo "❌ Secret not found in flux-system namespace. Check Reflector logs."
  exit 1
fi

echo "✅ Bootstrap complete!"