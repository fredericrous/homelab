#!/bin/bash
# Bootstrap script to create the vault transit token secret
# This should be run once after cluster creation

set -euo pipefail
trap 'echo ""; echo "❌ bootstrap vault transit secret interrupted by user"; exit 130' INT TERM
trap 'echo "DEBUG: Script failed at line $LINENO"' ERR

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Use provided token or load from environment
TRANSIT_TOKEN="${1:-${VAULT_TRANSIT_TOKEN:-}}"

# If not provided and not in environment, try .env file
if [ -z "$TRANSIT_TOKEN" ] && [ -f "$PROJECT_ROOT/.env" ]; then
  source "$PROJECT_ROOT/.env"
  TRANSIT_TOKEN="${VAULT_TRANSIT_TOKEN:-}"
fi

# If token is still not available, try to retrieve using simplified approach
if [ -z "$TRANSIT_TOKEN" ]; then
  echo "Vault transit token not found in env/args. Checking External Secrets..."
  if [ -f "$SCRIPT_DIR/simplified-token-retrieval.sh" ]; then
    # Get NAS token first, then use it to get transit token from NAS Vault
    if QNAP_VAULT_TOKEN=$("$SCRIPT_DIR/simplified-token-retrieval.sh" 2>/dev/null); then
      echo "✅ Retrieved NAS token, fetching transit token..."
      # Fetch transit token from NAS Vault using the retrieved token
      TRANSIT_TOKEN=$(curl -s \
        -H "X-Vault-Token: $QNAP_VAULT_TOKEN" \
        "http://192.168.1.42:61200/v1/secret/data/k8s-transit" | \
        jq -r '.data.data.token' 2>/dev/null || echo "")
      
      if [ -n "$TRANSIT_TOKEN" ] && [ "$TRANSIT_TOKEN" != "null" ]; then
        echo "✅ Successfully retrieved transit token from NAS Vault"
      else
        echo "❌ Could not retrieve transit token from NAS Vault"
        TRANSIT_TOKEN=""
      fi
    fi
  fi
fi

# If token is still not available, prompt for it
if [ -z "$TRANSIT_TOKEN" ]; then
  echo "Auto-retrieval failed. Vault transit token not found in arguments, environment, or .env file."
  echo ""
  echo "Options:"
  echo "1. Run 'task nas:vault-transit' to generate the token"
  echo "2. Or manually enter your Vault transit token:"
  read -s TRANSIT_TOKEN
  echo ""

  # Verify token was entered
  if [ -z "$TRANSIT_TOKEN" ]; then
    echo "ERROR: No token provided"
    exit 1
  fi
fi

# Create vault namespace if it doesn't exist
if ! kubectl get namespace vault >/dev/null 2>&1; then
  echo "Creating vault namespace..."
  kubectl create namespace vault
else
  echo "Vault namespace already exists"
fi

echo "Creating vault-transit-token secret in vault namespace..."

# Create the secret
kubectl create secret generic vault-transit-token \
  --namespace=vault \
  --from-literal=vault_transit_token="$TRANSIT_TOKEN" \
  --from-literal=token="$TRANSIT_TOKEN" \
  --save-config=true 2>/dev/null || \
kubectl create secret generic vault-transit-token \
  --namespace=vault \
  --from-literal=vault_transit_token="$TRANSIT_TOKEN" \
  --from-literal=token="$TRANSIT_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# Add annotations for Reflector
kubectl annotate secret vault-transit-token -n vault \
  reflector.v1.k8s.emberstack.com/reflection-allowed="true" \
  reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces="flux-system" \
  reflector.v1.k8s.emberstack.com/reflection-auto-enabled="true" \
  --overwrite

# Also create in flux-system namespace for platform-foundation
echo "Creating vault-transit-token secret in flux-system namespace..."
kubectl create secret generic vault-transit-token \
  --namespace=flux-system \
  --from-literal=vault_transit_token="$TRANSIT_TOKEN" \
  --from-literal=token="$TRANSIT_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ Secrets created successfully!"
echo ""
echo "Note: The secret is created in both vault and flux-system namespaces for bootstrap."
