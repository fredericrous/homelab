#!/bin/bash
# Don't use set -e because we want to continue even if some components aren't ready yet

echo "⏳ Waiting for infrastructure components to be ready..."

# Wait for Flux to create the kustomizations first
echo "Waiting for kustomizations to be created..."
for i in {1..30}; do
  if kubectl get kustomization infrastructure-core -n flux-system >/dev/null 2>&1; then
    echo "✓ infrastructure-core kustomization found"
    break
  fi
  echo "Waiting for infrastructure-core kustomization... ($i/30)"
  sleep 2
done

# Wait for infrastructure core first (includes Reflector, MetalLB, Rook-Ceph)
echo "Waiting for infrastructure core components..."
kubectl wait --for=condition=ready --timeout=300s -n flux-system kustomization/infrastructure-core 2>/dev/null || {
  echo "⚠️  Infrastructure core not ready yet, checking status..."
  kubectl get kustomization infrastructure-core -n flux-system 2>/dev/null || echo "Infrastructure-core kustomization not found"
}

# Wait for infrastructure kustomization to be ready
echo "Waiting for infrastructure reconciliation..."
kubectl wait --for=condition=ready --timeout=600s -n flux-system kustomization/infrastructure 2>/dev/null || {
  echo "⚠️  Infrastructure kustomization not ready yet, checking status..."
  kubectl get kustomization infrastructure -n flux-system 2>/dev/null || echo "Infrastructure kustomization not found"
}

# Wait for Vault HelmRelease
echo "Waiting for Vault..."
kubectl wait --for=condition=ready --timeout=600s -n flux-system helmrelease/vault 2>/dev/null || {
  echo "⚠️  Vault not ready yet"
  kubectl get helmrelease vault -n flux-system 2>/dev/null || echo "Vault HelmRelease not found"
}

# Wait for Vault to be initialized
echo "Waiting for Vault initialization..."
for i in {1..60}; do
  if kubectl get secret vault-admin-token -n vault >/dev/null 2>&1; then
    echo "✅ Vault is initialized"
    break
  fi
  echo "Waiting for Vault initialization... ($i/60)"
  sleep 10
done

# Wait for ESO
echo "Waiting for External Secrets Operator..."
kubectl wait --for=condition=ready --timeout=300s -n flux-system helmrelease/external-secrets 2>/dev/null || {
  echo "⚠️  ESO not ready yet"
  kubectl get helmrelease external-secrets -n flux-system 2>/dev/null || echo "ESO HelmRelease not found"
}

# Wait for other infrastructure
echo "Waiting for remaining infrastructure..."
kubectl wait --for=condition=ready --timeout=300s -n flux-system helmrelease/cert-manager 2>/dev/null || echo "⚠️  cert-manager not ready yet"
kubectl wait --for=condition=ready --timeout=300s -n flux-system helmrelease/haproxy-ingress 2>/dev/null || echo "⚠️  HAProxy not ready yet"
kubectl wait --for=condition=ready --timeout=300s -n flux-system helmrelease/cloudnative-pg 2>/dev/null || echo "⚠️  CloudNativePG not ready yet"
kubectl wait --for=condition=ready --timeout=300s -n flux-system helmrelease/rook-ceph 2>/dev/null || echo "⚠️  Rook-Ceph not ready yet"

echo ""
echo "🔍 Infrastructure status summary:"
echo "================================"
kubectl get kustomization -n flux-system 2>/dev/null | grep -E 'NAME|infrastructure|apps' || echo "No kustomizations found"
echo ""
echo "HelmReleases:"
kubectl get helmrelease -n flux-system 2>/dev/null || echo "No HelmReleases found"
echo ""
echo "Application deployment status:"
kubectl get kustomization -n flux-system apps 2>/dev/null || echo "⚠️  Applications kustomization not yet deployed"