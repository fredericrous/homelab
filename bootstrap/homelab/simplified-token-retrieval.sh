#!/bin/bash
# Simplified token retrieval using External Secrets Operator
# Leverages existing infrastructure instead of custom circuit breaker
set -euo pipefail

echo "🔄 Simplified Token Retrieval via External Secrets"

# Configuration
NAMESPACE="nas-integration"
SECRET_NAME="nas-vault-token"
MAX_WAIT_TIME=300  # 5 minutes
CHECK_INTERVAL=5   # 5 seconds

# Check if kubectl is available
if ! kubectl version --client >/dev/null 2>&1; then
    echo "❌ kubectl not available"
    exit 1
fi

# Check if cluster is accessible
if ! kubectl get nodes >/dev/null 2>&1; then
    echo "❌ Cluster not accessible"
    exit 1
fi

echo "✅ Cluster is accessible"

# Wait for External Secret to sync token
echo "⏳ Waiting for External Secret to sync NAS token..."

wait_start_time=$(date +%s)
while true; do
    current_time=$(date +%s)
    elapsed=$((current_time - wait_start_time))
    
    if [[ $elapsed -gt $MAX_WAIT_TIME ]]; then
        echo "❌ Timeout waiting for token sync after ${MAX_WAIT_TIME}s"
        
        # Show diagnostic information
        echo "🔍 Diagnostics:"
        echo "External Secret status:"
        kubectl get externalsecret nas-vault-token -n "$NAMESPACE" -o yaml 2>/dev/null || echo "  ExternalSecret not found"
        
        echo "Secret status:"
        kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" 2>/dev/null || echo "  Secret not found"
        
        echo "External Secrets Operator logs:"
        kubectl logs -n external-secrets-system -l app.kubernetes.io/name=external-secrets --tail=10 2>/dev/null || echo "  ESO logs not available"
        
        exit 1
    fi
    
    # Check if secret exists and has valid token
    if TOKEN=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null); then
        
        # Validate token format
        if [[ -n "$TOKEN" && "$TOKEN" =~ ^hvs\. ]]; then
            
            # Check token age/freshness
            LAST_REFRESH=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.metadata.annotations.homelab\.io/last-refresh}' 2>/dev/null || echo "")
            
            if [[ -n "$LAST_REFRESH" ]]; then
                echo "✅ Token retrieved successfully (last refresh: $LAST_REFRESH)"
            else
                echo "✅ Token retrieved successfully"
            fi
            
            # Output token for consumption
            echo "$TOKEN"
            exit 0
        else
            echo "⏳ Token format invalid, waiting for refresh... (${elapsed}s/${MAX_WAIT_TIME}s)"
        fi
    else
        echo "⏳ Waiting for token to be available... (${elapsed}s/${MAX_WAIT_TIME}s)"
    fi
    
    sleep $CHECK_INTERVAL
done