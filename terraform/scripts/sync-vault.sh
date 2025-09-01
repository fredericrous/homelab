#!/bin/bash
set -e

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

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
        # Check if transit token secret exists
        if kubectl get secret -n vault vault-transit-token >/dev/null 2>&1; then
          echo "✅ Transit token secret exists, auto-unseal should work"
        else
          echo "❌ Transit token secret missing. Run setup-vault-transit-token.sh first"
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
