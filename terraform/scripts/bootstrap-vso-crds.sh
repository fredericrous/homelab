#!/bin/bash
set -e

KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
export KUBECONFIG

echo "📦 Installing VSO CRDs to avoid circular dependencies..."

# Install only the CRDs, not the full VSO deployment
kubectl apply -f https://raw.githubusercontent.com/hashicorp/vault-secrets-operator/v0.10.0/chart/crds/secrets.hashicorp.com_vaultauths.yaml
kubectl apply -f https://raw.githubusercontent.com/hashicorp/vault-secrets-operator/v0.10.0/chart/crds/secrets.hashicorp.com_vaultauthglobals.yaml
kubectl apply -f https://raw.githubusercontent.com/hashicorp/vault-secrets-operator/v0.10.0/chart/crds/secrets.hashicorp.com_vaultconnections.yaml
kubectl apply -f https://raw.githubusercontent.com/hashicorp/vault-secrets-operator/v0.10.0/chart/crds/secrets.hashicorp.com_vaultstaticsecrets.yaml
kubectl apply -f https://raw.githubusercontent.com/hashicorp/vault-secrets-operator/v0.10.0/chart/crds/secrets.hashicorp.com_vaultdynamicsecrets.yaml
kubectl apply -f https://raw.githubusercontent.com/hashicorp/vault-secrets-operator/v0.10.0/chart/crds/secrets.hashicorp.com_vaultpkisecrets.yaml
kubectl apply -f https://raw.githubusercontent.com/hashicorp/vault-secrets-operator/v0.10.0/chart/crds/secrets.hashicorp.com_hcpauths.yaml
kubectl apply -f https://raw.githubusercontent.com/hashicorp/vault-secrets-operator/v0.10.0/chart/crds/secrets.hashicorp.com_hcpvaultsecretsapps.yaml
kubectl apply -f https://raw.githubusercontent.com/hashicorp/vault-secrets-operator/v0.10.0/chart/crds/secrets.hashicorp.com_secrettransformations.yaml

echo "✅ VSO CRDs installed successfully"
echo ""
echo "ℹ️  Note: This only installs the CRDs. The actual VSO operator will be"
echo "    deployed by ArgoCD along with Vault and other core services."