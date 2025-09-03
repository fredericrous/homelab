#!/bin/bash
# sync-vault.sh - Synchronizes Vault deployment and ensures transit unseal token is configured
#
# This script is called by Terraform during cluster deployment to:
# 1. Ensure Vault transit token secret exists (for auto-unseal via QNAP Vault)
# 2. Sync Vault application via ArgoCD
# 3. Wait for Vault to be initialized and running
#
# Transit Token Priority:
# 1. Secure file at /tmp/vault-transit-token (chmod 600)
# 2. Taskfile environment at /tmp/vault-transit-env (from prereq stage)
# 3. QNAP_VAULT_TOKEN environment variable (fetches from QNAP Vault via vault CLI)
#
# Security Notes:
# - Transit tokens are never logged or exposed
# - Secure files use 600 permissions
# - Tokens are cleared from memory on exit
# - Placeholder detection ensures proper token deployment
#
set -e

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

# Define secure token file paths
TRANSIT_TOKEN_FILE="${VAULT_TRANSIT_TOKEN_FILE:-/tmp/vault-transit-token}"
TRANSIT_ENV_FILE="/tmp/vault-transit-env"

# Cleanup function
cleanup() {
    # Clear sensitive data from memory
    unset K8S_VAULT_TRANSIT_TOKEN TEMP_K8S_VAULT_TRANSIT_TOKEN
    # Optionally remove transit token file after successful sync
    # rm -f "$TRANSIT_TOKEN_FILE" 2>/dev/null || true
}
trap cleanup EXIT

# Function to read transit token securely
read_transit_token() {
    local token=""
    
    # Priority 1: Read from secure file if exists
    if [ -f "$TRANSIT_TOKEN_FILE" ] && [ -r "$TRANSIT_TOKEN_FILE" ]; then
        echo "📋 Reading transit token from secure file..."
        token=$(cat "$TRANSIT_TOKEN_FILE")
        # Ensure file has secure permissions
        chmod 600 "$TRANSIT_TOKEN_FILE" 2>/dev/null || true
    # Priority 2: Check environment file from Taskfile
    elif [ -f "$TRANSIT_ENV_FILE" ]; then
        echo "📋 Loading transit token from Taskfile environment..."
        # Extract just the token value without sourcing
        token=$(grep "K8S_VAULT_TRANSIT_TOKEN=" "$TRANSIT_ENV_FILE" | cut -d'=' -f2- | tr -d '"')
    # Priority 3: Fall back to environment variable if provided by user
    elif [ -n "$QNAP_VAULT_TOKEN" ]; then
        echo "🔑 Using QNAP_VAULT_TOKEN from environment..."
        # Try to fetch from QNAP Vault if we have the vault CLI
        if command -v vault >/dev/null 2>&1; then
            echo "🔄 Fetching transit token from QNAP Vault..."
            export VAULT_ADDR=http://192.168.1.42:61200
            export VAULT_TOKEN="$QNAP_VAULT_TOKEN"
            token=$(vault kv get -field=token secret/k8s-transit 2>/dev/null || echo "")
            unset VAULT_ADDR VAULT_TOKEN
        fi
        
        # No fallback - must fetch from vault or use secure file
        if [ -z "$token" ]; then
            echo "❌ Failed to fetch transit token from QNAP Vault"
            echo "   Please ensure:"
            echo "   1. The vault CLI is installed, OR"
            echo "   2. The transit token exists in $TRANSIT_TOKEN_FILE, OR"
            echo "   3. The Taskfile has already set up the token in $TRANSIT_ENV_FILE"
            return 1
        fi
    fi
    
    echo "$token"
}

# Get the transit token securely
K8S_VAULT_TRANSIT_TOKEN=$(read_transit_token)

# Ensure transit token secret exists
if [ -n "$K8S_VAULT_TRANSIT_TOKEN" ]; then
    echo "🔑 Ensuring transit token secret exists..."
    
    # Create namespace if needed
    kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -
    
    # Check if secret already exists and has placeholder
    existing_token=$(kubectl get secret vault-transit-token -n vault -o json 2>/dev/null | jq -r '.data.token // empty' | base64 -d 2>/dev/null || echo "")
    
    if [ "$existing_token" = "PLACEHOLDER_WILL_BE_REPLACED_BY_TERRAFORM" ] || [ -z "$existing_token" ] || [ "$existing_token" != "$K8S_VAULT_TRANSIT_TOKEN" ]; then
        echo "🔄 Updating transit token secret..."
        # Create/update the secret
        kubectl create secret generic vault-transit-token \
            --namespace=vault \
            --from-literal=token="$K8S_VAULT_TRANSIT_TOKEN" \
            --dry-run=client -o yaml | kubectl apply -f -
        echo "✅ Transit token secret created/updated"
    else
        echo "✅ Transit token secret already up to date"
    fi
    
    # Write to secure file for future runs if not already there
    if [ ! -f "$TRANSIT_TOKEN_FILE" ]; then
        echo "💾 Saving transit token to secure file for future use..."
        echo "$K8S_VAULT_TRANSIT_TOKEN" > "$TRANSIT_TOKEN_FILE"
        chmod 600 "$TRANSIT_TOKEN_FILE"
    fi
else
    echo "⚠️  Transit token not available, Vault might fail to unseal"
fi

# Clear the token from memory
unset K8S_VAULT_TRANSIT_TOKEN

echo "🔐 Waiting for Vault application to be created by ApplicationSet..."
timeout 150s bash -c 'until kubectl get app -n argocd vault >/dev/null 2>&1; do
  echo "Waiting for Vault application..."
  sleep 5
done'

if [ $? -eq 0 ]; then
  echo "✅ Vault application found"
else
  echo "❌ Timeout waiting for Vault application"
  exit 1
fi

echo "🔐 Syncing Vault application..."
# Force sync Vault app
kubectl patch app -n argocd vault --type merge -p '{"operation":{"initiatedBy":{"username":"terraform"},"sync":{"prune":true,"syncStrategy":{"hook":{}}}}}'

# Wait for sync to complete
echo "⏳ Waiting for Vault sync to complete..."
timeout 600s bash -c 'while true; do
  sync_status=$(kubectl get app -n argocd vault -o jsonpath="{.status.sync.status}" 2>/dev/null || echo "Unknown")
  health_status=$(kubectl get app -n argocd vault -o jsonpath="{.status.health.status}" 2>/dev/null || echo "Unknown")
  
  # Check if vault pod exists and what state it is in
  vault_pod_status=$(kubectl get pod -n vault vault-0 -o jsonpath="{.status.phase}" 2>/dev/null || echo "NotFound")
  
  if [ "$sync_status" = "Synced" ]; then
    echo "✅ Vault synced (Health: $health_status)"
    exit 0
  fi
  
  # If sync is OutOfSync but vault pod exists, that is progress
  if [ "$sync_status" = "OutOfSync" ] && [ "$vault_pod_status" != "NotFound" ]; then
    echo "✅ Vault pod exists (Status: $vault_pod_status, Health: $health_status)"
    echo "   Note: Health may show as Missing due to pending sync-wave jobs"
    exit 0
  fi
  
  echo "Sync status: $sync_status, Health: $health_status, Pod: $vault_pod_status"
  sleep 5
done'

if [ $? -ne 0 ]; then
  echo "❌ Timeout waiting for Vault sync"
  exit 1
fi

# Wait for Vault namespace and PVC
echo "⏳ Waiting for Vault PVC to be bound..."
timeout 300s bash -c 'while true; do
  pvc_status=$(kubectl get pvc -n vault vault-data -o jsonpath="{.status.phase}" 2>/dev/null || echo "NotFound")
  if [ "$pvc_status" = "Bound" ]; then
    echo "✅ Vault PVC is bound"
    exit 0
  elif [ "$pvc_status" = "Pending" ]; then
    # Get more details about why it is pending
    echo "PVC is Pending. Recent events:"
    kubectl get events -n vault --field-selector involvedObject.name=vault-data --sort-by=".lastTimestamp" | tail -5
  fi
  echo "PVC status: $pvc_status"
  sleep 5
done'

if [ $? -ne 0 ]; then
  echo "❌ Timeout waiting for Vault PVC"
  exit 1
fi

# Wait for Vault pod to exist
echo "⏳ Waiting for Vault pod to be created..."
timeout 300s bash -c 'until kubectl get pod -n vault vault-0 >/dev/null 2>&1; do
  echo "Waiting for Vault pod..."
  sleep 5
done'

if [ $? -eq 0 ]; then
  echo "✅ Vault pod exists"
else
  echo "❌ Timeout waiting for Vault pod"
  exit 1
fi

# Wait for Vault to be ready (but it might be sealed)
echo "⏳ Waiting for Vault pod to be running..."
kubectl wait --for=condition=ready --timeout=300s pod -n vault vault-0 || \
kubectl wait --for=jsonpath='{.status.phase}'=Running --timeout=300s pod -n vault vault-0 || true

# Check if Vault is initialized
echo "🔍 Checking Vault initialization status..."

timeout 300s bash -c 'while true; do
  # Check if initialization secrets exist
  if kubectl get secret -n vault vault-keys >/dev/null 2>&1 && kubectl get secret -n vault vault-admin-token >/dev/null 2>&1; then
    echo "✅ Vault initialization secrets found"

    # Check Vault health endpoint
    vault_health=$(kubectl exec -n vault vault-0 -- sh -c "vault status -format=json 2>&1 || echo {}" 2>/dev/null || echo "{}")
    if echo "$vault_health" | grep -q "initialized.*true" >/dev/null 2>&1; then
      echo "✅ Vault is initialized"
      if echo "$vault_health" | grep -q "sealed.*false" >/dev/null 2>&1; then
        echo "✅ Vault is unsealed and ready (likely using transit auto-unseal)"
      else
        echo "⚠️  Vault is sealed, checking transit unseal configuration..."
        # Check if transit token secret exists and is not a placeholder
        if kubectl get secret -n vault vault-transit-token >/dev/null 2>&1; then
          token_value=$(kubectl get secret vault-transit-token -n vault -o json | jq -r '.data.token' | base64 -d)
          if [ "$token_value" = "PLACEHOLDER_WILL_BE_REPLACED_BY_TERRAFORM" ]; then
            echo "❌ Transit token secret has placeholder value. Attempting to fix..."
            # Re-read the transit token
            TEMP_K8S_VAULT_TRANSIT_TOKEN=$(read_transit_token)
            if [ -n "$TEMP_K8S_VAULT_TRANSIT_TOKEN" ]; then
              kubectl delete secret vault-transit-token -n vault
              kubectl create secret generic vault-transit-token \
                --namespace=vault \
                --from-literal=token="$TEMP_K8S_VAULT_TRANSIT_TOKEN"
              echo "✅ Transit token secret updated"
              # Restart Vault pod to pick up new token
              echo "🔄 Restarting Vault pod to apply new transit token..."
              kubectl delete pod vault-0 -n vault
              sleep 10
            else
              echo "❌ Transit token not available to update the secret"
              echo "   Please ensure QNAP_VAULT_TOKEN is set or transit token file exists"
              exit 1
            fi
          else
            echo "✅ Transit token secret exists, auto-unseal should work"
          fi
        else
          echo "❌ Transit token secret missing. Creating it now..."
          TEMP_K8S_VAULT_TRANSIT_TOKEN=$(read_transit_token)
          if [ -n "$TEMP_K8S_VAULT_TRANSIT_TOKEN" ]; then
            kubectl create secret generic vault-transit-token \
              --namespace=vault \
              --from-literal=token="$TEMP_K8S_VAULT_TRANSIT_TOKEN"
            echo "✅ Transit token secret created"
          else
            echo "❌ Transit token not available"
            echo "   Please ensure QNAP_VAULT_TOKEN is set or transit token file exists"
            exit 1
          fi
        fi
      fi
    fi
    # Exit successfully if secrets exist, even if they are placeholders
    echo "ℹ️  Note: If these are placeholder secrets due to Vault 1.20.1 auto-initialization,"
    echo "    Vault operations will fail until properly initialized with known keys."
    exit 0
  fi

  # Check init job status
  if kubectl get job -n vault vault-init >/dev/null 2>&1; then
    init_job_status=$(kubectl get job -n vault vault-init -o jsonpath="{.status.conditions[?(@.type==\"Complete\")].status}" 2>/dev/null || echo "Running")
    init_job_failed=$(kubectl get job -n vault vault-init -o jsonpath="{.status.conditions[?(@.type==\"Failed\")].status}" 2>/dev/null || echo "False")

    if [ "$init_job_status" = "True" ]; then
      echo "✅ Vault init job completed successfully"
      exit 0
    elif [ "$init_job_failed" = "True" ]; then
      echo "❌ Vault init job failed. Checking logs..."
      kubectl logs -n vault job/vault-init --tail=20
      exit 1
    else
      echo "⏳ Vault init job is running..."
      # Show last few log lines to see progress
      kubectl logs -n vault job/vault-init --tail=5 2>/dev/null || true

      # Check if the logs show Vault is already initialized (auto-init issue)
      if kubectl logs -n vault job/vault-init 2>/dev/null | grep -q "WARNING: Vault is already initialized"; then
        echo "⚠️  Vault auto-initialized without providing keys (known issue with v1.20.1)"
        echo "ℹ️  Creating placeholder secrets to unblock deployment..."

        # Check if placeholder secrets already exist
        if kubectl get secret -n vault vault-admin-token >/dev/null 2>&1; then
          echo "✅ Placeholder secrets already exist"
          exit 0
        fi

        echo "❌ Vault 1.20.1 auto-initialization detected. Manual intervention required."
        echo "   Run: kubectl apply -f manifests/core/vault/job-create-placeholder-secrets.yaml"
        exit 1
      fi
    fi
  fi

  echo "Waiting for Vault initialization..."
  sleep 5
done'

if [ $? -ne 0 ]; then
  echo "❌ Timeout waiting for Vault initialization"
  exit 1
fi

echo "✅ Vault synced successfully"
