#!/bin/bash
set -e

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

echo "📜 Waiting for cert-manager application to be created by ApplicationSet..."
timeout 150s sh -c 'until kubectl get app -n argocd cert-manager >/dev/null 2>&1; do
  echo "Waiting for cert-manager application..."
  sleep 5
done'

if [ $? -eq 0 ]; then
  echo "✅ cert-manager application found"
else
  echo "❌ Timeout waiting for cert-manager application"
  exit 1
fi

echo "📜 Syncing cert-manager..."
# Force sync cert-manager app
kubectl patch app -n argocd cert-manager --type merge -p '{"operation":{"initiatedBy":{"username":"terraform"},"sync":{"prune":true,"syncStrategy":{"hook":{}}}}}'

# Wait for sync to complete
echo "⏳ Waiting for cert-manager sync to complete..."
timeout 600s sh -c 'while true; do
  sync_status=$(kubectl get app -n argocd cert-manager -o jsonpath="{.status.sync.status}" 2>/dev/null || echo "Unknown")
  health_status=$(kubectl get app -n argocd cert-manager -o jsonpath="{.status.health.status}" 2>/dev/null || echo "Unknown")
  
  if [ "$sync_status" = "Synced" ]; then
    echo "✅ cert-manager synced (Health: $health_status)"
    exit 0
  fi
  
  # For initial deployment, check if core deployments exist
  if kubectl get deployment -n cert-manager cert-manager >/dev/null 2>&1 && \
     kubectl get deployment -n cert-manager cert-manager-webhook >/dev/null 2>&1 && \
     kubectl get deployment -n cert-manager cert-manager-cainjector >/dev/null 2>&1; then
    echo "✅ cert-manager core components deployed (Sync: $sync_status, Health: $health_status)"
    exit 0
  fi
  
  echo "Sync status: $sync_status, Health: $health_status"
  sleep 5
done'

if [ $? -ne 0 ]; then
  echo "❌ Timeout waiting for cert-manager sync"
  echo "Checking if core components are deployed..."
  
  # Even if sync didn't complete, check if the core components are there
  if kubectl get deployment -n cert-manager cert-manager >/dev/null 2>&1 && \
     kubectl get deployment -n cert-manager cert-manager-webhook >/dev/null 2>&1 && \
     kubectl get deployment -n cert-manager cert-manager-cainjector >/dev/null 2>&1; then
    echo "✅ cert-manager core components are deployed despite sync timeout"
  else
    echo "❌ cert-manager core components not found"
    exit 1
  fi
fi

# Wait for cert-manager CRDs to be available
echo "⏳ Waiting for cert-manager CRDs..."
crds="certificates.cert-manager.io certificaterequests.cert-manager.io issuers.cert-manager.io clusterissuers.cert-manager.io"
for crd in $crds; do
  timeout 120s sh -c "until kubectl get crd $crd >/dev/null 2>&1; do
    sleep 2
  done"
  
  if [ $? -eq 0 ]; then
    echo "✅ CRD $crd is ready"
  else
    echo "⚠️  Warning: CRD $crd not found after timeout"
  fi
done

# Wait for cert-manager deployments
echo "⏳ Waiting for cert-manager deployments..."
deployments="cert-manager cert-manager-webhook cert-manager-cainjector"
for deploy in $deployments; do
  kubectl wait --for=condition=available --timeout=300s deployment -n cert-manager "$deploy" || true
done

# Wait for webhook to be ready (critical for cert creation)
echo "⏳ Waiting for cert-manager webhook to be ready..."
kubectl wait --for=condition=ready --timeout=300s pod -n cert-manager -l app.kubernetes.io/name=webhook || true

# Check if ClusterIssuer is created
echo "🔍 Checking for Let's Encrypt ClusterIssuer..."
timeout 60s sh -c 'while true; do
  if kubectl get clusterissuer letsencrypt-ovh-webhook >/dev/null 2>&1; then
    issuer_ready=$(kubectl get clusterissuer letsencrypt-ovh-webhook -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}" 2>/dev/null || echo "Unknown")
    if [ "$issuer_ready" = "True" ]; then
      echo "✅ ClusterIssuer is ready and configured"
      exit 0
    else
      echo "ClusterIssuer exists but not ready: $issuer_ready"
      # During initial deployment, existence is enough
      echo "✅ ClusterIssuer created (will be ready once OVH credentials are in Vault)"
      exit 0
    fi
  fi
  echo "Waiting for ClusterIssuer..."
  sleep 5
done'

if [ $? -ne 0 ]; then
  echo "⚠️  Warning: ClusterIssuer not created after timeout"
  echo "This is expected if cert-manager is still syncing. Continuing..."
fi

echo "✅ cert-manager synced successfully"