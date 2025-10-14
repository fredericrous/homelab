#!/bin/bash
# Test script for Vault token rotation
set -euo pipefail

KUBECONFIG_QNAP="${KUBECONFIG_QNAP:-./infrastructure/nas/kubeconfig.yaml}"

echo "🧪 Testing Vault Token Rotation"
echo "================================"

# Check if kubeconfig exists
if [ ! -f "$KUBECONFIG_QNAP" ]; then
    echo "❌ NAS kubeconfig not found at $KUBECONFIG_QNAP"
    echo "   Run 'task nas:install' first"
    exit 1
fi

export KUBECONFIG="$KUBECONFIG_QNAP"

# Check if cluster is accessible
echo "🔍 Checking NAS cluster connectivity..."
if ! kubectl get nodes >/dev/null 2>&1; then
    echo "❌ Cannot connect to NAS cluster"
    exit 1
fi
echo "✅ NAS cluster is accessible"

# Check if Vault is running
echo "🏪 Checking Vault deployment..."
if ! kubectl get pods -n vault -l app.kubernetes.io/name=vault | grep -q Running; then
    echo "❌ Vault is not running in the NAS cluster"
    exit 1
fi
echo "✅ Vault is running"

# Check if token-rotation resources exist
echo "🔄 Checking token rotation resources..."
if ! kubectl get serviceaccount token-rotator -n vault >/dev/null 2>&1; then
    echo "❌ token-rotator service account not found"
    echo "   Token rotation may not be deployed yet"
    exit 1
fi
echo "✅ Token rotation service account exists"

if ! kubectl get cronjob vault-token-rotation -n vault >/dev/null 2>&1; then
    echo "❌ vault-token-rotation CronJob not found"
    exit 1
fi
echo "✅ Token rotation CronJob exists"

# Show current token rotation status
echo ""
echo "📊 Current Token Rotation Status:"
echo "================================="

# Show CronJob schedule and last run
kubectl get cronjob vault-token-rotation -n vault -o custom-columns="NAME:.metadata.name,SCHEDULE:.spec.schedule,SUSPEND:.spec.suspend,ACTIVE:.status.active,LAST-SCHEDULE:.status.lastScheduleTime"

# Show recent jobs
echo ""
echo "📋 Recent Token Rotation Jobs:"
kubectl get jobs -n vault -l app=vault-token-rotation --sort-by=.metadata.creationTimestamp | tail -5

# Option to trigger manual rotation
echo ""
echo "🔧 Manual Token Rotation Options:"
echo "================================="
echo "1. View rotation logs: kubectl logs -n vault -l job-name=vault-token-rotation --tail=50"
echo "2. Trigger manual rotation:"
echo "   kubectl apply -f kubernetes/nas/apps/token-rotation/manual-rotation-job.yaml"
echo "3. Check current root token age:"
echo "   ./bootstrap/homelab/auto-retrieve-qnap-token.sh && echo 'Token retrieved successfully'"

# Ask user if they want to trigger manual rotation
read -p "🤔 Do you want to trigger a manual token rotation now? (y/N): " -r
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🚀 Triggering manual token rotation..."
    kubectl delete job manual-vault-token-rotation -n vault --ignore-not-found=true
    kubectl apply -f kubernetes/nas/apps/token-rotation/manual-rotation-job.yaml
    
    echo "⏳ Waiting for job to start..."
    sleep 5
    
    echo "📋 Following job logs:"
    kubectl logs -n vault -l job-name=manual-vault-token-rotation -f
    
    echo ""
    echo "✅ Manual token rotation completed!"
    echo "🧪 Testing token retrieval with new token..."
    
    if ./bootstrap/homelab/auto-retrieve-qnap-token.sh >/dev/null 2>&1; then
        echo "✅ New token retrieval successful!"
    else
        echo "❌ New token retrieval failed - check rotation logs"
    fi
else
    echo "ℹ️  Manual rotation skipped"
fi

echo ""
echo "✅ Token rotation test completed!"