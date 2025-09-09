#!/bin/bash
# Script to ensure vault-transit-unseal-operator is working correctly

set -e

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "🔍 Checking vault-transit-unseal-operator..."

# Check if operator is running
if ! kubectl get deployment vault-transit-unseal-operator -n vault-transit-unseal-operator &>/dev/null; then
    echo "❌ Operator not deployed"
    exit 1
fi

# Check operator pods
DEPLOYMENT_READY=$(kubectl get deployment vault-transit-unseal-operator -n vault-transit-unseal-operator -o json | jq '.status.conditions[] | select(.type=="Progressing") | .status=="True" and .reason=="NewReplicaSetAvailable"')
READY_REPLICAS=$(kubectl get deployment vault-transit-unseal-operator -n vault-transit-unseal-operator -o json | jq '.status.readyReplicas // 0')
EXPECTED_REPLICAS=$(kubectl get deployment vault-transit-unseal-operator -n vault-transit-unseal-operator -o json | jq '.spec.replicas // 1')

if [[ "$READY_REPLICAS" -eq 0 ]] || [[ "$READY_REPLICAS" -ne "$EXPECTED_REPLICAS" ]]; then
    echo "⚠️  Operator deployment not ready ($READY_REPLICAS/$EXPECTED_REPLICAS)"
    echo "🔄 Restarting operator..."
    kubectl rollout restart deployment vault-transit-unseal-operator -n vault-transit-unseal-operator
    kubectl rollout status deployment vault-transit-unseal-operator -n vault-transit-unseal-operator --timeout=120s
fi

# Check if VaultTransitUnseal exists
if ! kubectl get vaulttransitunseal vault-main -n vault &>/dev/null; then
    echo "⚠️  VaultTransitUnseal resource missing"
    echo "🔄 Re-applying vault configuration..."
    kubectl apply -k "${PROJECT_ROOT}/manifests/core/vault/"
fi

# Check if postUnsealConfig is present
if ! kubectl get vaulttransitunseal vault-main -n vault -o yaml | grep -q "postUnsealConfig:"; then
    echo "⚠️  VaultTransitUnseal missing postUnsealConfig"
    echo "🔄 Re-applying vault configuration..."
    kubectl apply -f "${PROJECT_ROOT}/manifests/core/vault/vault-transit-unseal.yaml"
fi

# Force reconciliation
echo "🔄 Triggering reconciliation..."
kubectl annotate vaulttransitunseal vault-main -n vault reconcile="$(date +%s)" --overwrite

# Check logs for recent activity
echo "📋 Checking operator logs..."
if kubectl logs -n vault-transit-unseal-operator deployment/vault-transit-unseal-operator --since=30s | grep -q "Configuring\|configurator\|postUnseal"; then
    echo "✅ Operator is processing configuration"
else
    echo "⚠️  No recent configuration activity"
fi

echo "✅ Vault operator check complete"
