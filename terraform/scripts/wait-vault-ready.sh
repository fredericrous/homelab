#!/bin/bash
# Wait for Vault to be ready and initialized
set -e

KUBECONFIG="${1:-$KUBECONFIG}"
export KUBECONFIG

echo "⏳ Waiting for Vault to be ready..."

# Wait for pod to exist
for i in {1..60}; do
    if kubectl get pod -n vault vault-0 &>/dev/null; then
        break
    fi
    echo "   Waiting for Vault pod to be created... ($i/60)"
    sleep 5
done

# Wait for pod to be ready
kubectl wait --for=condition=Ready pod/vault-0 -n vault --timeout=300s || true

# Check if Vault is initialized
for i in {1..30}; do
    if kubectl exec -n vault vault-0 -- vault status 2>&1 | grep -q "Initialized.*true"; then
        echo "✅ Vault is initialized"
        
        # Check if it needs unsealing
        if kubectl exec -n vault vault-0 -- vault status 2>&1 | grep -q "Sealed.*true"; then
            echo "🔓 Vault needs unsealing..."
            
            # Try to unseal with stored key
            UNSEAL_KEY=$(kubectl get secret -n vault vault-keys -o jsonpath='{.data.unseal-key}' | base64 -d 2>/dev/null || echo "")
            if [ -n "$UNSEAL_KEY" ]; then
                kubectl exec -n vault vault-0 -- vault operator unseal "$UNSEAL_KEY" || true
                echo "✅ Vault unsealed"
            else
                echo "⚠️  No unseal key found - Vault will remain sealed"
            fi
        fi
        
        exit 0
    fi
    
    echo "   Waiting for Vault initialization... ($i/30)"
    sleep 10
done

echo "⚠️  Vault initialization timeout - continuing anyway"
exit 0