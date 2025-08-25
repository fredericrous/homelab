# HashiCorp Vault for Secret Management

Minimal Vault setup for managing PostgreSQL credentials with automatic rotation.

## Components

- **Vault**: v1.17.6 with file storage backend
- **Storage**: 10Gi Rook Ceph volume
- **UI Access**: NodePort 30200

## Deployment Steps

1. **Deploy Vault**:
   ```bash
   kubectl apply -k .
   ```

2. **Vault Initialization**:
   Vault is automatically initialized by the `job-vault-init.yaml` job included in the kustomization.
   The job stores the unseal key and admin token in Kubernetes secrets.

3. **Access Vault UI**:
   - URL: `http://<node-ip>:30200`
   - Token: Get from secret: `kubectl get secret vault-admin-token -n vault -o jsonpath='{.data.token}' | base64 -d`

## Getting Credentials

To access Vault:
```bash
# Port forward to Vault
kubectl -n vault port-forward svc/vault 8200:8200

# Export credentials
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(kubectl get secret vault-admin-token -n vault -o jsonpath='{.data.token}' | base64 -d)

# View secrets
vault kv list secret/
vault kv get secret/<path>
```

## Features

- Automatic password rotation
- TTL-based credentials (1 hour default, 24 hour max)
- Web UI for management
- Kubernetes authentication integration

## Unsealing Vault

If Vault needs to be unsealed (after pod restart):
```bash
# Get unseal key
UNSEAL_KEY=$(kubectl get secret vault-keys -n vault -o jsonpath='{.data.unseal-key}' | base64 -d)

# Unseal vault
kubectl exec -n vault vault-0 -- vault operator unseal $UNSEAL_KEY
```

The `job-vault-unseal.yaml` job will also automatically unseal Vault when deployed.
