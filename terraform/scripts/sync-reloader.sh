#!/bin/bash
# sync-reloader.sh - Deploy and sync Stakater Reloader
#
# This script ensures Stakater Reloader is deployed via ArgoCD.
# Reloader watches for ConfigMap and Secret changes and restarts pods.
#
set -e

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

echo "🔄 Waiting for Stakater Reloader application to be created by ApplicationSet..."
KUBECONFIG_PATH="$KUBECONFIG"
timeout 150s bash -c "export KUBECONFIG='$KUBECONFIG_PATH'; until kubectl get app -n argocd stakater-reloader >/dev/null 2>&1; do
  echo \"Waiting for Reloader application...\"
  sleep 5
done"

if [ $? -eq 0 ]; then
  echo "✅ Reloader application found"
else
  echo "❌ Timeout waiting for Reloader application"
  exit 1
fi

echo "🔄 Syncing Stakater Reloader..."
# Create namespace if it doesn't exist
kubectl create namespace stakater-reloader --dry-run=client -o yaml | kubectl apply -f -

# Force sync Reloader app
echo "🔄 Initiating Reloader sync..."
kubectl patch app -n argocd stakater-reloader --type merge -p '{"operation":{"initiatedBy":{"username":"terraform"},"sync":{"prune":true}}}'

# Wait for sync to complete
echo "⏳ Waiting for Reloader sync to complete..."
timeout 300s bash -c "export KUBECONFIG='$KUBECONFIG_PATH'; while true; do
  sync_status=\$(kubectl get app -n argocd stakater-reloader -o jsonpath=\"{.status.sync.status}\" 2>/dev/null || echo \"Unknown\")
  health_status=\$(kubectl get app -n argocd stakater-reloader -o jsonpath=\"{.status.health.status}\" 2>/dev/null || echo \"Unknown\")
  
  if [ \"\$sync_status\" = \"Synced\" ]; then
    echo \"✅ Reloader synced (Health: \$health_status)\"
    break
  fi
  
  # Check if deployment exists
  if kubectl get deployment -n stakater-reloader reloader-reloader >/dev/null 2>&1; then
    echo \"✅ Reloader deployment exists (Sync: \$sync_status, Health: \$health_status)\"
    break
  fi
  
  echo \"Sync status: \$sync_status, Health: \$health_status\"
  sleep 5
done"

if [ $? -ne 0 ]; then
  echo "❌ Timeout waiting for Reloader sync"
  exit 1
fi

# Wait for Reloader to be ready
echo "⏳ Waiting for Reloader pods to be ready..."
kubectl wait --for=condition=ready --timeout=120s pod -n stakater-reloader -l app.kubernetes.io/name=reloader || true

# Verify Reloader is working
echo "🔍 Checking Reloader status..."
if kubectl get deployment -n stakater-reloader reloader-reloader >/dev/null 2>&1; then
  replicas=$(kubectl get deployment -n stakater-reloader reloader-reloader -o jsonpath="{.status.readyReplicas}" 2>/dev/null || echo "0")
  # Handle empty string case
  replicas="${replicas:-0}"
  if [ "$replicas" -gt 0 ]; then
    echo "✅ Reloader is running with $replicas ready replicas"
    
    # Show Reloader configuration
    echo "📋 Reloader configuration:"
    kubectl get deployment -n stakater-reloader reloader-reloader -o jsonpath="{.spec.template.spec.containers[0].args}" | jq -r '.[]' 2>/dev/null || true
    
    # Check for any pods with reloader annotations
    echo "🔍 Checking for pods with reloader annotations..."
    annotated_pods=$(kubectl get pods --all-namespaces -o json | jq -r '.items[] | select(.metadata.annotations | has("reloader.stakater.com/auto") or has("configmap.reloader.stakater.com/reload") or has("secret.reloader.stakater.com/reload")) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || echo "")
    
    if [ -n "$annotated_pods" ]; then
      echo "📋 Found pods with reloader annotations:"
      echo "$annotated_pods"
    else
      echo "ℹ️  No pods with reloader annotations found yet"
      echo "   Add annotations to your deployments to enable auto-reload:"
      echo "   - reloader.stakater.com/auto: \"true\""
      echo "   - configmap.reloader.stakater.com/reload: \"<configmap-name>\""
      echo "   - secret.reloader.stakater.com/reload: \"<secret-name>\""
    fi
  else
    echo "⚠️  Reloader deployment exists but no ready replicas"
    exit 1
  fi
else
  echo "❌ Reloader deployment not found"
  exit 1
fi

echo "✅ Stakater Reloader synced successfully!"
echo "ℹ️  Reloader will automatically restart pods when their ConfigMaps or Secrets change"
echo "   Use annotations on your deployments to enable this feature"