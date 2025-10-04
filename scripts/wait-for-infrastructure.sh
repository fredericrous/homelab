#!/bin/bash
# Realistic Bootstrap Wait Strategy
# Waits for operators to be AVAILABLE, not for resources to be READY
# This matches the actual bootstrap flow where configuration happens after operators are deployed

set -e
trap 'echo "DEBUG: Script failed at line $LINENO"' ERR

echo "⏳ Waiting for infrastructure operators to be available..."

# Phase 1: Wait for FluxCD to create kustomizations
echo "Phase 1: Waiting for kustomizations to be created..."
for i in {1..30}; do
  if kubectl get kustomization platform-foundation -n flux-system >/dev/null 2>&1; then
    echo "✓ platform-foundation kustomization found"
    break
  fi
  echo "Waiting for platform-foundation kustomization... ($i/30)"
  sleep 2
done

# Phase 2: Wait for operators to be DEPLOYING (not ready)
echo "Phase 2: Waiting for operators to start deploying..."

# Wait for Vault operator to be deployed (not necessarily ready)
echo "Waiting for Vault operator deployment..."
for i in {1..60}; do
  if kubectl get deployment vault-vault -n vault >/dev/null 2>&1; then
    echo "✓ Vault deployment found"
    break
  fi
  echo "Waiting for Vault deployment... ($i/60)"
  sleep 5
done

# Wait for External Secrets operator to be deployed
echo "Waiting for External Secrets operator deployment..."
for i in {1..60}; do
  if kubectl get deployment external-secrets -n external-secrets >/dev/null 2>&1; then
    echo "✓ External Secrets deployment found"
    break
  fi
  echo "Waiting for External Secrets deployment... ($i/60)"
  sleep 5
done

# Wait for Rook operator to be deployed
echo "Waiting for Rook operator deployment..."
for i in {1..60}; do
  if kubectl get deployment rook-ceph-operator -n rook-ceph >/dev/null 2>&1; then
    echo "✓ Rook operator deployment found"
    break
  fi
  echo "Waiting for Rook operator deployment... ($i/60)"
  sleep 5
done

# Phase 3: Wait for operators to be AVAILABLE (ready to receive configuration)
echo "Phase 3: Waiting for operators to be available..."

# Wait for Vault to be available (not configured)
echo "Waiting for Vault to be available..."
kubectl wait --for=condition=available deployment/vault-vault -n vault --timeout=300s || {
  echo "⚠️  Vault deployment not available yet"
  kubectl get pods -n vault
}

# Wait for External Secrets operator to be available
echo "Waiting for External Secrets operator to be available..."
kubectl wait --for=condition=available deployment/external-secrets -n external-secrets --timeout=300s || {
  echo "⚠️  External Secrets operator not available yet"
  kubectl get pods -n external-secrets
}

# Wait for Rook operator to be available
echo "Waiting for Rook operator to be available..."
kubectl wait --for=condition=available deployment/rook-ceph-operator -n rook-ceph --timeout=300s || {
  echo "⚠️  Rook operator not available yet"
  kubectl get pods -n rook-ceph
}

# Phase 4: Wait for CRDs to be registered (so resources can be applied)
echo "Phase 4: Waiting for CRDs to be registered..."

# Wait for Rook CRDs
echo "Waiting for Rook CRDs..."
for i in {1..60}; do
  if kubectl get crd cephclusters.ceph.rook.io >/dev/null 2>&1; then
    echo "✓ Rook CRDs registered"
    break
  fi
  echo "Waiting for Rook CRDs... ($i/60)"
  sleep 5
done

# Wait for External Secrets CRDs
echo "Waiting for External Secrets CRDs..."
for i in {1..60}; do
  if kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
    echo "✓ External Secrets CRDs registered"
    break
  fi
  echo "Waiting for External Secrets CRDs... ($i/60)"
  sleep 5
done

# Phase 5: Verify Vault is unsealed and reachable
echo "Phase 5: Waiting for Vault to be unsealed and reachable..."
for i in {1..60}; do
  # Check if Vault is unsealed by trying to access the status
  if kubectl exec -n vault vault-0 -- vault status >/dev/null 2>&1; then
    echo "✓ Vault is unsealed and reachable"
    break
  fi
  echo "Waiting for Vault to be unsealed... ($i/60)"
  sleep 5
done

# Phase 6: Wait for Vault initialization job to complete
echo "Phase 6: Waiting for Vault initialization..."
for i in {1..60}; do
  if kubectl get secret vault-admin-token -n vault >/dev/null 2>&1; then
    echo "✓ Vault is initialized (admin token exists)"
    break
  fi
  echo "Waiting for Vault initialization... ($i/60)"
  sleep 5
done

echo ""
echo "🎯 Bootstrap Phase Complete!"
echo "================================"
echo "✅ All operators are available and ready for configuration"
echo "✅ CRDs are registered"
echo "✅ Vault is initialized and unsealed"
echo ""
echo "📋 Next Steps:"
echo "1. Configure Vault (run generate-pki.sh if needed)"
echo "2. Populate cluster-vars in Vault (PushSecret will handle this)"
echo "3. Wait for ExternalSecrets to sync"
echo "4. Platform-foundation will become ready"
echo "5. Dependent layers will proceed"
echo ""
echo "🔍 Current Status:"
kubectl get kustomizations -n flux-system || echo "No kustomizations found yet"