#!/bin/bash
# Configure External Secrets Operator to sync from NAS Vault
# This script sets up the ESO token for cross-cluster sync

set -e

# Parameters
KUBECONFIG="${1:?Error: KUBECONFIG path required as first argument}"
NAS_VAULT_TOKEN="${2:?Error: NAS Vault ESO token required as second argument}"

export KUBECONFIG

echo "🔐 Configuring External Secrets Operator for NAS Vault sync..."

# Wait for External Secrets namespace
echo "⏳ Waiting for external-secrets namespace..."
until kubectl get namespace external-secrets >/dev/null 2>&1; do
  echo "   Waiting for namespace..."
  sleep 5
done

# Create/update the secret with NAS Vault token
echo "🎫 Creating NAS Vault token secret..."
kubectl create secret generic nas-vault-token \
  --namespace=external-secrets \
  --from-literal=token="$NAS_VAULT_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ NAS Vault token configured"

# Wait for ClusterSecretStore to be ready
echo "⏳ Waiting for NAS ClusterSecretStore..."

# First try kubectl wait for efficiency
if kubectl wait clustersecretstore nas-vault-backend \
  --for=condition=Ready \
  --timeout=300s 2>&1 | grep -q "condition met"; then
  echo "✅ NAS Vault backend is ready"
else
  # Fallback to manual checking with more details
  echo "   kubectl wait didn't succeed, checking status manually..."
  
  MAX_ATTEMPTS=30
  ATTEMPT=1
  
  while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    if kubectl get clustersecretstore nas-vault-backend >/dev/null 2>&1; then
      # Get detailed status information
      STATUS=$(kubectl get clustersecretstore nas-vault-backend -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
      REASON=$(kubectl get clustersecretstore nas-vault-backend -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")
      MESSAGE=$(kubectl get clustersecretstore nas-vault-backend -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
      
      # Display status with more context
      echo -n "   Attempt $ATTEMPT/$MAX_ATTEMPTS - Status: $STATUS"
      [ -n "$REASON" ] && echo -n " (Reason: $REASON)"
      echo ""
      [ -n "$MESSAGE" ] && echo "   Message: $MESSAGE"
      
      if [ "$STATUS" = "True" ]; then
        echo "✅ NAS Vault backend is ready"
        break
      fi
      
      # Show provider status as well
      PROVIDER_STATUS=$(kubectl get clustersecretstore nas-vault-backend -o jsonpath='{.status.conditions[?(@.type=="SecretStoreProvider")].status}' 2>/dev/null || echo "")
      [ -n "$PROVIDER_STATUS" ] && echo "   Provider status: $PROVIDER_STATUS"
    else
      echo "   ClusterSecretStore not found yet (Attempt $ATTEMPT/$MAX_ATTEMPTS)"
    fi
    
    if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
      echo "⚠️  ClusterSecretStore not ready after $MAX_ATTEMPTS attempts"
      echo "   Current status:"
      kubectl get clustersecretstore nas-vault-backend -o yaml | grep -A20 "^status:" || echo "   No status found"
      echo ""
      echo "   This is expected if:"
      echo "   - NAS Vault is not accessible from this cluster"
      echo "   - The ESO token is invalid or expired"
      echo ""
      echo "   The ClusterSecretStore will become ready when:"
      echo "   1. NAS Vault is accessible at http://192.168.1.42:61200"
      echo "   2. A valid ESO token is configured"
      echo ""
      echo "   Continuing deployment - CA sync will not work until this is resolved"
      break
    fi
    
    sleep 5
    ((ATTEMPT++))
  done
fi

# Create the CA sync ExternalSecret if it doesn't exist
if ! kubectl get externalsecret sync-ca-from-nas -n vault >/dev/null 2>&1; then
  echo "🔄 Creating CA sync ExternalSecret..."
  kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: sync-ca-from-nas
  namespace: vault
spec:
  refreshInterval: 5m
  
  secretStoreRef:
    name: nas-vault-backend
    kind: ClusterSecretStore
  
  target:
    name: nas-ca-cert-temp
    creationPolicy: Owner
    deletionPolicy: Delete
  
  data:
  - secretKey: ca_crt
    remoteRef:
      key: secret/data/pki/ca
      property: ca.crt
EOF
  echo "✅ CA sync ExternalSecret created"
else
  echo "✅ CA sync ExternalSecret already exists"
fi

# Create sync job to push CA to main Vault
echo "🔄 Creating CA sync job..."
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: sync-ca-to-vault
  namespace: vault
spec:
  backoffLimit: 3
  template:
    spec:
      serviceAccountName: vault
      restartPolicy: OnFailure
      containers:
      - name: sync
        image: bitnami/kubectl:latest
        command:
        - /bin/bash
        - -c
        - |
          set -e
          
          echo "Waiting for ESO to create temporary secret..."
          MAX_WAIT=60
          WAITED=0
          while ! kubectl get secret nas-ca-cert-temp -n vault >/dev/null 2>&1; do
            if [ $WAITED -ge $MAX_WAIT ]; then
              echo "Timeout waiting for secret"
              exit 1
            fi
            echo "Still waiting..."
            sleep 5
            WAITED=$((WAITED + 5))
          done
          
          echo "Secret found, extracting CA certificate..."
          CA_CERT=$(kubectl get secret nas-ca-cert-temp -n vault -o jsonpath='{.data.ca_crt}' | base64 -d)
          
          if [ -z "$CA_CERT" ]; then
            echo "CA certificate is empty!"
            exit 1
          fi
          
          echo "CA certificate starts with:"
          echo "$CA_CERT" | head -n 3
          
          # Create a job to push to Vault
          kubectl apply -f - <<VAULT_JOB
          apiVersion: batch/v1
          kind: Job
          metadata:
            name: push-ca-to-vault-$(date +%s)
            namespace: vault
          spec:
            template:
              spec:
                serviceAccountName: vault
                restartPolicy: Never
                containers:
                - name: vault
                  image: vault:1.14.1
                  env:
                  - name: VAULT_ADDR
                    value: http://vault:8200
                  command:
                  - /bin/sh
                  - -c
                  - |
                    set -e
                    
                    # Get admin token from secret
                    export VAULT_TOKEN=\$(cat /vault/admin-token/token)
                    
                    # Wait for Vault to be ready
                    until vault status >/dev/null 2>&1; do
                      echo "Waiting for Vault..."
                      sleep 2
                    done
                    
                    # Store CA in Vault
                    echo "Storing CA in Vault..."
                    vault kv put secret/client-ca ca.crt="$(echo "$CA_CERT" | sed 's/$/\\n/' | tr -d '\n' | sed 's/\\n$//')"
                    
                    echo "✅ CA certificate synced to main Vault"
                  volumeMounts:
                  - name: admin-token
                    mountPath: /vault/admin-token
                    readOnly: true
                volumes:
                - name: admin-token
                  secret:
                    secretName: vault-admin-token
          VAULT_JOB
EOF

echo ""
echo "🎯 NAS Vault sync configuration complete!"
echo ""
echo "📋 Next steps:"
echo "1. Check ExternalSecret status:"
echo "   kubectl get externalsecret sync-ca-from-nas -n vault"
echo "2. Check if CA is synced to Vault:"
echo "   kubectl exec -n vault vault-0 -- vault kv get secret/client-ca"
echo "3. Verify HAProxy has the CA:"
echo "   kubectl get secret client-ca-cert -n haproxy-controller"