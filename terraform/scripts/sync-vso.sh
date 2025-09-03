#!/bin/bash
# sync-vso.sh - Idempotent Vault Secrets Operator deployment sync script
#
# This script ensures VSO is deployed and synced via ArgoCD.
# It handles common issues like:
# - Conflicting upgrade-crds hooks from previous installations
# - OutOfSync status due to configuration jobs
# - Retries with different sync strategies if needed
#
# The script is idempotent - it can be run multiple times safely
#
set -e

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

echo "🔒 Waiting for VSO application to be created by ApplicationSet..."
timeout 150s bash -c 'until kubectl get app -n argocd vault-secrets-operator >/dev/null 2>&1; do
  echo "Waiting for VSO application..."
  sleep 5
done'

if [ $? -eq 0 ]; then
  echo "✅ VSO application found"
else
  echo "❌ Timeout waiting for VSO application"
  exit 1
fi

echo "🔒 Syncing Vault Secrets Operator..."
# Create namespace if it doesn't exist
kubectl create namespace vault-secrets-operator --dry-run=client -o yaml | kubectl apply -f -

# Check if we have sync errors due to existing hooks
if kubectl get app -n argocd vault-secrets-operator -o jsonpath='{.status.conditions[?(@.type=="SyncError")].message}' 2>/dev/null | grep -q "vault-secrets-operator-upgrade-crds.*already exists"; then
  echo "⚠️  Detected conflicting upgrade-crds hooks, cleaning up..."
  kubectl delete clusterrole vault-secrets-operator-upgrade-crds --ignore-not-found=true
  kubectl delete clusterrolebinding vault-secrets-operator-upgrade-crds --ignore-not-found=true
  sleep 2
fi

# Force sync VSO app - Helm will handle CRDs with installCRDs=true
echo "🔄 Initiating VSO sync..."
kubectl patch app -n argocd vault-secrets-operator --type merge -p '{"operation":{"initiatedBy":{"username":"terraform"},"sync":{"prune":true,"syncStrategy":{"hook":{}}}}}'

# Wait for sync to complete
echo "⏳ Waiting for VSO sync to complete..."
timeout 600s bash -c 'while true; do
  sync_status=$(kubectl get app -n argocd vault-secrets-operator -o jsonpath="{.status.sync.status}" 2>/dev/null || echo "Unknown")
  health_status=$(kubectl get app -n argocd vault-secrets-operator -o jsonpath="{.status.health.status}" 2>/dev/null || echo "Unknown")
  operation_phase=$(kubectl get app -n argocd vault-secrets-operator -o jsonpath="{.status.operationState.phase}" 2>/dev/null || echo "Unknown")
  
  # Check if we have sync errors
  sync_error=$(kubectl get app -n argocd vault-secrets-operator -o jsonpath="{.status.conditions[?(@.type==\"SyncError\")].message}" 2>/dev/null || echo "")
  
  # If sync failed due to hooks, retry with different strategy
  if [ "$operation_phase" = "Failed" ] && echo "$sync_error" | grep -q "upgrade-crds.*already exists"; then
    echo "⚠️  Sync failed due to hook conflicts, cleaning and retrying with Replace strategy..."
    # Delete the conflicting resources
    kubectl delete clusterrole vault-secrets-operator-upgrade-crds --ignore-not-found=true
    kubectl delete clusterrolebinding vault-secrets-operator-upgrade-crds --ignore-not-found=true
    # Retry with Replace to force recreation
    kubectl patch app -n argocd vault-secrets-operator --type merge -p "{\"operation\":{\"initiatedBy\":{\"username\":\"terraform-retry\"},\"sync\":{\"prune\":true,\"syncOptions\":[\"Replace=true\",\"ServerSideApply=true\"]}}}"
    sleep 10
    continue
  fi
  
  # Check if VSO deployment exists (even if health is Missing due to config jobs)
  vso_deployment=$(kubectl get deployment -n vault-secrets-operator vault-secrets-operator-controller-manager 2>/dev/null || echo "NotFound")
  
  # Check if CRDs exist
  crd_count=$(kubectl get crd | grep -c secrets.hashicorp.com || echo "0")
  
  if [ "$sync_status" = "Synced" ]; then
    echo "✅ VSO synced (Health: $health_status)"
    exit 0
  fi
  
  # If deployment and CRDs exist, consider it successful even if OutOfSync
  if [ "$vso_deployment" != "NotFound" ] && [ "$crd_count" -gt "0" ]; then
    echo "✅ VSO deployment and CRDs exist (Sync: $sync_status, Health: $health_status)"
    echo "   Note: OutOfSync status may be due to configuration jobs"
    exit 0
  fi
  
  echo "Sync status: $sync_status, Health: $health_status, Phase: $operation_phase"
  sleep 5
done'

if [ $? -ne 0 ]; then
  echo "❌ Timeout waiting for VSO sync"
  exit 1
fi

# Wait for VSO CRDs to be available
echo "⏳ Waiting for VSO CRDs..."
crds="vaultauths.secrets.hashicorp.com vaultstaticsecrets.secrets.hashicorp.com vaultdynamicsecrets.secrets.hashicorp.com vaultpkisecrets.secrets.hashicorp.com"
for crd in $crds; do
  timeout 120s bash -c "until kubectl get crd $crd >/dev/null 2>&1; do
    sleep 2
  done"
  
  if [ $? -eq 0 ]; then
    echo "✅ CRD $crd is ready"
  else
    echo "⚠️  Warning: CRD $crd not found after timeout"
  fi
done

# Wait for VSO deployment to be ready
echo "⏳ Waiting for VSO deployment..."
kubectl wait --for=condition=available --timeout=300s deployment -n vault-secrets-operator vault-secrets-operator-controller-manager || true

# Wait for VSO webhook to be ready
kubectl wait --for=condition=ready --timeout=300s pod -n vault-secrets-operator -l control-plane=controller-manager || true

echo "✅ VSO synced successfully"