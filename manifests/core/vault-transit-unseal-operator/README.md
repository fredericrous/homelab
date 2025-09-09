# Vault Transit Unseal Operator

This operator manages Vault initialization, unsealing, and post-unseal configuration.

## Features

1. **Automatic Vault Initialization** with transit unseal
2. **Post-Unseal Configuration**:
   - Enables KV v2 engine at `/secret`
   - Configures Kubernetes auth
   - Sets up External Secrets Operator (ESO) access
3. **Auto-CRD Installation**: CRDs are installed/updated automatically on operator startup

## Known Issues

If the operator image fails to pull with 401 Unauthorized:

1. The image is public and can be verified with:
   ```bash
   docker manifest inspect ghcr.io/fredericrous/vault-transit-unseal-operator:0.3.0
   ```

2. If cluster cannot pull, manually configure Vault:
   ```bash
   # Enable Kubernetes auth
   kubectl exec -n vault vault-0 -- vault auth enable kubernetes
   kubectl exec -n vault vault-0 -- vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443
   
   # ESO is configured automatically by the operator's postUnsealConfig
   ```

## Deployment

```bash
kubectl apply -k manifests/core/vault-transit-unseal-operator/
```

The operator will:
1. Watch for VaultTransitUnseal resources
2. Initialize Vault if needed
3. Configure post-unseal settings from the CRD

## Idempotency

The deployment is idempotent:
- CRDs are installed/updated automatically on operator startup
- VaultTransitUnseal resource includes postUnsealConfig
- Operator reconciles on changes
