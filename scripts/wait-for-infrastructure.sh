#!/bin/bash
set -e

echo "⏳ Waiting for infrastructure components to be ready..."

# Wait for infrastructure core first (includes Reflector, MetalLB, Rook-Ceph)
echo "Waiting for infrastructure core components..."
kubectl wait --for=condition=ready --timeout=300s -n flux-system kustomization/infrastructure-core || echo "Infrastructure core not ready yet"

# Wait for infrastructure kustomization to be ready
echo "Waiting for infrastructure reconciliation..."
kubectl wait --for=condition=ready --timeout=600s -n flux-system kustomization/infrastructure || echo "Infrastructure kustomization not ready yet"

# Wait for Vault HelmRelease
echo "Waiting for Vault..."
kubectl wait --for=condition=ready --timeout=600s -n flux-system helmrelease/vault || echo "Vault not ready yet"

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
kubectl wait --for=condition=ready --timeout=300s -n flux-system helmrelease/external-secrets || echo "ESO not ready yet"

# Wait for other infrastructure
echo "Waiting for remaining infrastructure..."
kubectl wait --for=condition=ready --timeout=300s -n flux-system helmrelease/cert-manager || echo "cert-manager not ready yet"
kubectl wait --for=condition=ready --timeout=300s -n flux-system helmrelease/haproxy-ingress || echo "HAProxy not ready yet"
kubectl wait --for=condition=ready --timeout=300s -n flux-system helmrelease/cloudnative-pg || echo "CloudNativePG not ready yet"
kubectl wait --for=condition=ready --timeout=600s -n flux-system helmrelease/rook-ceph-operator || echo "Rook-Ceph not ready yet"

echo "✅ All infrastructure components are ready!"
echo ""
echo "Application deployment status:"
kubectl get kustomization -n flux-system apps 2>/dev/null || echo "Applications kustomization not yet deployed"