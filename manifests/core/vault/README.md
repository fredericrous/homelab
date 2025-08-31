# HashiCorp Vault for Secret Management

Vault setup with transit auto-unseal for managing secrets and credentials.

## Components

- **Vault**: v1.17.6 with file storage backend
- **Auto-Unseal**: Transit unseal using QNAP Vault
- **Storage**: 10Gi Rook Ceph volume
- **UI Access**: Via ingress at vault.daddyshome.fr

## Prerequisites

1. **QNAP Vault** must be running and configured for transit unseal
2. **Transit token secret** must be created:
   ```bash
   kubectl create secret generic vault-transit-token \
     --namespace=vault \
     --from-literal=token=<TOKEN_FROM_QNAP>
   ```

## Deployment

### Via ArgoCD (Recommended)

The Vault application is deployed automatically by ArgoCD with proper ordering:
1. Transit token validation (PreSync)
2. Vault deployment
3. Automatic initialization (PostSync)
4. Configuration for other apps

### Manual Deployment

```bash
# Create namespace and transit token secret first
kubectl create namespace vault
kubectl create secret generic vault-transit-token \
  --namespace=vault \
  --from-literal=token=<TOKEN_FROM_QNAP>

# Deploy Vault
kubectl apply -k .
```

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

## Auto-Unseal with Transit

Vault uses transit unseal with QNAP Vault, which means:
- **No manual unsealing required** - Vault auto-unseals on startup
- **No unseal keys to manage** - QNAP Vault handles the unsealing
- **Automatic recovery** - Vault recovers automatically after crashes

For details, see [TRANSIT-UNSEAL-SETUP.md](./TRANSIT-UNSEAL-SETUP.md)
