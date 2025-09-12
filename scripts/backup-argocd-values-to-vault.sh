#!/bin/bash
set -euo pipefail

echo "🔐 Backing up ArgoCD environment values to Vault..."

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ kubectl not found"
    exit 1
fi

# Check if vault CLI is available
if ! command -v vault &> /dev/null; then
    echo "❌ vault CLI not found"
    exit 1
fi

# Get the ConfigMap values
echo "📥 Retrieving values from ConfigMap..."
if ! kubectl get configmap argocd-envsubst-values -n argocd &>/dev/null; then
    echo "❌ ConfigMap argocd-envsubst-values not found in argocd namespace"
    exit 1
fi

# Extract the values
VALUES=$(kubectl get configmap argocd-envsubst-values -n argocd -o jsonpath='{.data.values}')

if [ -z "$VALUES" ]; then
    echo "❌ No values found in ConfigMap"
    exit 1
fi

# Setup Vault connection
if [ -z "${VAULT_ADDR:-}" ]; then
    echo "🔗 Setting up Vault connection..."
    kubectl port-forward -n vault svc/vault 8200:8200 &
    PF_PID=$!
    sleep 3
    export VAULT_ADDR=http://127.0.0.1:8200
fi

# Get Vault token if not set
if [ -z "${VAULT_TOKEN:-}" ]; then
    echo "🔑 Getting Vault token..."
    export VAULT_TOKEN=$(kubectl get secret vault-admin-token -n vault -o jsonpath='{.data.token}' | base64 -d)
fi

# Convert values to JSON format for Vault
echo "📝 Converting values to Vault format..."
JSON_DATA="{"
first=true
while IFS= read -r line; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    
    # Extract key and value
    if [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        
        # Add comma if not first entry
        if [ "$first" = false ]; then
            JSON_DATA+=","
        fi
        first=false
        
        # Escape quotes in value and add to JSON
        value_escaped=$(echo "$value" | sed 's/"/\\"/g')
        JSON_DATA+="\"$key\":\"$value_escaped\""
    fi
done <<< "$VALUES"
JSON_DATA+="}"

# Write to Vault
echo "💾 Writing values to Vault at secret/argocd/env-values..."
if echo "$JSON_DATA" | vault kv put secret/argocd/env-values -; then
    echo "✅ Successfully backed up ArgoCD values to Vault"
    
    # Show what was stored
    echo ""
    echo "📋 Stored values:"
    vault kv get -format=json secret/argocd/env-values | jq -r '.data.data | to_entries | .[] | "\(.key)=***"'
    
    echo ""
    echo "🔄 The External Secrets Operator will now sync these values"
    echo "   Check status: kubectl get externalsecret -n argocd argocd-envsubst-values-external"
else
    echo "❌ Failed to write values to Vault"
    exit 1
fi

# Cleanup port-forward if we started it
if [ -n "${PF_PID:-}" ]; then
    kill $PF_PID 2>/dev/null || true
fi

echo ""
echo "💡 Next steps:"
echo "   1. Values are now backed up in Vault"
echo "   2. External Secrets Operator will sync them to a Secret"
echo "   3. If ConfigMap is lost, the plugin will use the Secret as fallback"
echo "   4. To manually trigger sync:"
echo "      kubectl annotate externalsecret -n argocd argocd-envsubst-values-external force-sync=\$(date +%s)"