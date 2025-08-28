#!/bin/bash
set -e

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

echo "✅ Core services deployed. Cluster is ready!"
echo ""
echo "📋 Service Status:"
kubectl get app -n argocd vault vault-secrets-operator cert-manager -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
echo ""
echo "🌐 To access ArgoCD:"
echo "  - URL: https://argocd.daddyshome.fr/"
echo "  - Username: admin"
echo "  - Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"
echo ""
echo "⚠️  Note: HTTPS access requires your mTLS client certificate"