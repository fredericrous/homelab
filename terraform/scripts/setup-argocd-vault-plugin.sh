#!/bin/bash
set -euo pipefail

# Script to setup ArgoCD Vault Plugin configuration
# This creates the secret with NAS vault credentials for bootstrap

KUBECONFIG="${1:-}"
if [ -z "$KUBECONFIG" ]; then
    echo "Error: kubeconfig path required as first argument"
    exit 1
fi

export KUBECONFIG="$KUBECONFIG"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}🔐 Setting up ArgoCD Vault Plugin configuration${NC}"

# Load environment variables
if [ -f ../.env ]; then
    set -a
    source ../.env
    set +a
fi

# Get NAS vault configuration - using direct variable names from .env
NAS_VAULT_ADDR="${ARGO_NAS_VAULT_ADDR:-http://192.168.1.42:61200}"
NAS_VAULT_TOKEN="${QNAP_VAULT_TOKEN:-}"

if [ -z "$NAS_VAULT_TOKEN" ]; then
    echo -e "${RED}❌ Error: QNAP_VAULT_TOKEN not set${NC}"
    echo "Please export QNAP_VAULT_TOKEN with your NAS vault root token"
    exit 1
fi

# Create ArgoCD namespace if it doesn't exist
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Create AVP configuration secret
echo -e "${YELLOW}📝 Creating argocd-vault-plugin-config secret...${NC}"
kubectl create secret generic argocd-vault-plugin-config \
    --namespace=argocd \
    --from-literal=AVP_TYPE="vault" \
    --from-literal=AVP_AUTH_TYPE="token" \
    --from-literal=AVP_VAULT_ADDR="$NAS_VAULT_ADDR" \
    --from-literal=AVP_TOKEN="$NAS_VAULT_TOKEN" \
    --from-literal=AVP_SECRET_PATH="secret/data/bootstrap" \
    --dry-run=client -o yaml | kubectl apply -f -

echo -e "${GREEN}✅ AVP configuration created successfully${NC}"

# Verify bootstrap secrets exist
echo -e "${YELLOW}🔍 Verifying bootstrap secrets in NAS vault...${NC}"
if command -v vault &>/dev/null; then
    export VAULT_ADDR="$NAS_VAULT_ADDR"
    export VAULT_TOKEN="$NAS_VAULT_TOKEN"
    
    if vault kv get secret/bootstrap/config &>/dev/null; then
        echo -e "${GREEN}✅ Bootstrap secrets verified${NC}"
    else
        echo -e "${RED}❌ Error: Bootstrap secrets not found in NAS vault${NC}"
        echo "Please run: task nas:vault-transit"
        exit 1
    fi
else
    echo -e "${YELLOW}⚠️  Cannot verify - vault CLI not found${NC}"
fi

echo -e "${GREEN}✅ ArgoCD Vault Plugin setup complete!${NC}"
echo ""
echo "Note: After cluster vault is initialized, update AVP config to use cluster vault:"
echo "  kubectl edit secret argocd-vault-plugin-config -n argocd"