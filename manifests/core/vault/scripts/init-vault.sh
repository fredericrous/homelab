#!/bin/sh
set -e

# Wait for Vault pod to be accessible
echo "Waiting for Vault to be ready..."
timeout 60s sh -c 'until vault status >/dev/null 2>&1 || [ $? -eq 2 ]; do
  echo "Waiting for Vault..."
  sleep 2
done'

if [ $? -eq 0 ]; then
  echo "Vault is responding"
else
  echo "Timeout waiting for Vault to be ready"
  exit 1
fi

# Check if already initialized FIRST before doing anything else
echo "Checking vault initialization status..."
init_status=$(vault operator init -status 2>&1 || true)
echo "Init status: $init_status"

if echo "$init_status" | grep -q "Vault is initialized"; then
  echo "Vault is already initialized"
  
  # Check if keys exist in secrets
  if kubectl get secret -n vault vault-keys >/dev/null 2>&1 && kubectl get secret -n vault vault-admin-token >/dev/null 2>&1; then
    echo "Vault secrets already exist. Nothing to do."
    exit 0
  else
    echo "WARNING: Vault is initialized but secrets are missing!"
    echo "This is a recovery scenario - the keys must be provided manually."
    echo ""
    echo "Checking for recovery secrets..."
    
    # Check if recovery secrets were provided
    if [ -f /recovery/unseal-key ] && [ -f /recovery/root-token ]; then
      echo "Recovery secrets found! Recreating Kubernetes secrets..."
      
      UNSEAL_KEY=$(cat /recovery/unseal-key)
      ROOT_TOKEN=$(cat /recovery/root-token)
      
      # Create the secrets
      kubectl create secret generic vault-keys \
        --namespace=vault \
        --from-literal=unseal-key="$UNSEAL_KEY" \
        --from-literal=root-token="$ROOT_TOKEN" \
        --dry-run=client -o yaml | kubectl apply -f -
      
      kubectl create secret generic vault-root-token \
        --namespace=vault \
        --from-literal=root-token="$ROOT_TOKEN" \
        --dry-run=client -o yaml | kubectl apply -f -
      
      echo "Unsealing Vault with recovered key..."
      vault operator unseal "$UNSEAL_KEY"
      
      # Create admin token
      export VAULT_TOKEN="$ROOT_TOKEN"
      echo "Creating admin token..."
      vault auth enable kubernetes || true
      
      # Create admin policy
      vault policy write admin-policy - <<'POLICY'
# Full access to all paths
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
POLICY
      
      ADMIN_TOKEN_OUTPUT=$(vault token create -policy=admin-policy -period=768h)
      ADMIN_TOKEN=$(echo "$ADMIN_TOKEN_OUTPUT" | grep "^token " | awk '{print $2}')
      
      kubectl create secret generic vault-admin-token \
        --namespace=vault \
        --from-literal=token="$ADMIN_TOKEN" \
        --dry-run=client -o yaml | kubectl apply -f -
      
      echo "Recovery complete! Vault secrets have been recreated."
      exit 0
    else
      echo ""
      echo "MANUAL RECOVERY REQUIRED!"
      echo "========================"
      echo ""
      echo "To recover, you need to provide the Vault unseal key and root token."
      echo ""
      echo "Option 1: If you have the keys, create a ConfigMap with them:"
      echo "  kubectl create configmap vault-recovery -n vault \\"
      echo "    --from-literal=unseal-key='YOUR_UNSEAL_KEY' \\"
      echo "    --from-literal=root-token='YOUR_ROOT_TOKEN'"
      echo ""
      echo "Option 2: If keys are lost, you must reset Vault (DATA LOSS!):"
      echo "  1. Delete the Vault StatefulSet: kubectl delete sts -n vault vault"
      echo "  2. Delete the PVC: kubectl delete pvc -n vault vault-data"
      echo "  3. Re-sync the Vault app in ArgoCD"
      echo ""
      echo "Then delete this job and let ArgoCD recreate it."
      exit 1
    fi
  fi
fi

echo "Proceeding with vault initialization..."
echo "Initializing Vault..."
INIT_OUTPUT=$(vault operator init -key-shares=1 -key-threshold=1)

# Extract values using grep and sed
UNSEAL_KEY=$(echo "$INIT_OUTPUT" | grep "Unseal Key" | sed 's/Unseal Key.*: //')
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | grep "Initial Root Token" | sed 's/Initial Root Token: //')

# Create secret with unseal key and root token
kubectl create secret generic vault-keys \
  --namespace=vault \
  --from-literal=unseal-key="$UNSEAL_KEY" \
  --from-literal=root-token="$ROOT_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

# Also create the vault-root-token secret for backward compatibility
kubectl create secret generic vault-root-token \
  --namespace=vault \
  --from-literal=root-token="$ROOT_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Vault initialization complete. Secrets created."

# Unseal Vault
echo "Unsealing Vault..."
vault operator unseal "$UNSEAL_KEY"

# Configure Vault with admin service account
export VAULT_TOKEN="$ROOT_TOKEN"

echo "Enabling secrets engines..."
vault secrets enable -path=secret kv-v2 || true
vault auth enable kubernetes || true

echo "Configuring Kubernetes auth..."
vault write auth/kubernetes/config \
  kubernetes_host=https://$KUBERNETES_PORT_443_TCP_ADDR:443

# Create admin policy with full privileges
echo "Creating admin policy..."
vault policy write admin-policy - <<'POLICY'
# Full access to all paths
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
POLICY

# Create admin service account token
echo "Creating admin token..."
ADMIN_TOKEN_OUTPUT=$(vault token create -policy=admin-policy -period=768h)
ADMIN_TOKEN=$(echo "$ADMIN_TOKEN_OUTPUT" | grep "^token " | awk '{print $2}')

# Save admin token as secret
kubectl create secret generic vault-admin-token \
  --namespace=vault \
  --from-literal=token="$ADMIN_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Vault initialization and configuration complete!"