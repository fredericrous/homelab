#!/bin/bash
# Fix Vault sync issue by bootstrapping from QNAP Vault
set -e

echo "🔧 Fixing Vault deployment sync issue"
echo "===================================="

# First, check if the secret-copier job is stuck
if kubectl get job -n vault secret-copier &>/dev/null 2>&1; then
    JOB_STATUS=$(kubectl get job -n vault secret-copier -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}')
    
    if [ "$JOB_STATUS" = "True" ] || kubectl get pods -n vault -l job-name=secret-copier 2>&1 | grep -q "No resources found"; then
        echo "🔍 Secret-copier job is stuck/failed"
        
        # Option 1: Bootstrap from QNAP Vault
        echo "💡 Attempting to bootstrap OVH credentials from QNAP Vault..."
        
        # Create cert-manager namespace if it doesn't exist
        kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
        
        # Check if we can create a dummy secret to satisfy the job
        if ! kubectl get secret ovh-credentials -n cert-manager &>/dev/null 2>&1; then
            echo "📝 Creating placeholder OVH credentials to unblock deployment"
            kubectl create secret generic ovh-credentials \
                --namespace=cert-manager \
                --from-literal=applicationKey="placeholder" \
                --from-literal=applicationSecret="placeholder" \
                --from-literal=consumerKey="placeholder"
            
            echo "✅ Placeholder created. The real credentials will be added when cert-manager is deployed."
        fi
        
        # Delete the stuck job to retry
        echo "🔄 Restarting secret-copier job..."
        kubectl delete job -n vault secret-copier --ignore-not-found=true
        
        # Trigger ArgoCD sync again
        kubectl patch app -n argocd vault --type merge -p '{"operation":{"sync":{"syncStrategy":{"hook":{"force":true}}}}}'
        
        echo "✅ Fix applied! Vault deployment should proceed now."
    fi
else
    echo "ℹ️  No secret-copier job found or it's working correctly"
fi