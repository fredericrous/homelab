#!/bin/bash
set -e

echo "⏳ Waiting for infrastructure components to be ready..."

# Wait for Vault
echo "Waiting for Vault..."
kubectl wait --for=condition=ready --timeout=600s -n vault kustomization/vault

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

# Wait for VSO
echo "Waiting for Vault Secrets Operator..."
kubectl wait --for=condition=ready --timeout=300s -n flux-system kustomization/vault-secrets-operator

# Wait for other infrastructure
echo "Waiting for remaining infrastructure..."
kubectl wait --for=condition=ready --timeout=300s -n flux-system kustomization/cert-manager
kubectl wait --for=condition=ready --timeout=300s -n flux-system kustomization/haproxy-ingress
kubectl wait --for=condition=ready --timeout=300s -n flux-system kustomization/cloudnative-pg
kubectl wait --for=condition=ready --timeout=600s -n flux-system kustomization/rook-ceph-operator

echo "✅ All infrastructure components are ready!"
echo ""
echo "Application deployment status:"
kubectl get kustomization -n flux-system lldap authelia 2>/dev/null || echo "Applications not yet deployed"