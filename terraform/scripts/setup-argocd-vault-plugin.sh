#!/bin/bash
set -euo pipefail

# Script to setup ArgoCD Vault Plugin configuration
# This creates the secret with NAS vault credentials for bootstrap

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${PROJECT_ROOT}/.env"

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

# Load environment variables if .env exists
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# Get NAS vault configuration - using direct variable names from .env
NAS_VAULT_ADDR="${ARGO_NAS_VAULT_ADDR:-http://192.168.1.42:61200}"

# Try multiple sources for the NAS vault token
NAS_VAULT_TOKEN=""

# Priority 1: Environment variable
if [ -n "${QNAP_VAULT_TOKEN:-}" ]; then
    echo -e "${YELLOW}Using QNAP vault token from environment variable${NC}"
    NAS_VAULT_TOKEN="$QNAP_VAULT_TOKEN"
# Priority 2: Read from .env file if it exists
elif [ -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}Looking for QNAP vault token in .env file${NC}"
    NAS_VAULT_TOKEN=$(grep "^QNAP_VAULT_TOKEN=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | sed 's/^export //')
    if [ -n "$NAS_VAULT_TOKEN" ]; then
        echo -e "${GREEN}Found QNAP vault token in .env file${NC}"
    fi
fi

if [ -z "$NAS_VAULT_TOKEN" ]; then
    echo -e "${RED}❌ Error: QNAP_VAULT_TOKEN not found${NC}"
    echo ""
    echo "Please provide the QNAP Vault token via one of:"
    echo "1. Export QNAP_VAULT_TOKEN environment variable"
    echo "2. Add QNAP_VAULT_TOKEN to your .env file"
    echo "3. Run: task nas:vault-transit to set up the token"
    echo ""
    echo "The token can be found in your CLAUDE.local.md file or QNAP Vault initialization output"
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
        echo -e "${YELLOW}⚠️  Warning: Could not verify bootstrap secrets in NAS vault${NC}"
        echo "If secrets are missing, run: task nas:vault-transit"
        # Don't fail - let AVP handle the actual verification
    fi
else
    echo -e "${YELLOW}⚠️  Cannot verify - vault CLI not found${NC}"
    echo "AVP will verify secrets during deployment"
fi

echo -e "${GREEN}✅ ArgoCD Vault Plugin setup complete!${NC}"
echo ""
echo "Note: After cluster vault is initialized, update AVP config to use cluster vault:"
echo "  kubectl edit secret argocd-vault-plugin-config -n argocd"