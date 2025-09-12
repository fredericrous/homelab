# Vault Configuration Guide

## QNAP Transit Vault Address Configuration

The QNAP vault address is now configured using the `argocd-envsubst-plugin` which reads from the `.env` file in the repository root.

### Current Configuration
- **Address**: `${QNAP_VAULT_ADDR}` (configured in `.env` file)
- **Mount Path**: `transit`
- **Key Name**: `autounseal`

### To Change the QNAP Vault Address

1. Edit the `.env` file in the repository root:
```bash
QNAP_VAULT_ADDR=http://NEW-IP:61200
```

2. Commit and push the change
3. ArgoCD will automatically sync and the envsubst plugin will replace the variable

### How It Works

1. The `vault` app in ArgoCD is configured to use the `envsubst` plugin (see `app.yaml`)
2. The plugin reads variables from `.env` file in the repository root
3. All `${VARIABLE}` placeholders in YAML files are replaced with their values
4. This allows centralized configuration management across the entire homelab

### Configuration Files Using QNAP_VAULT_ADDR

- `vault-config.yaml`: Vault's main configuration with transit seal block
- `nas-vault-config.yaml`: ConfigMap with transit vault configuration
- `vault-transit-unseal.yaml`: VaultTransitUnseal CRD default value

## External Secrets Operator (ESO) Configuration

The ESO ClusterSecretStore for NAS also uses the QNAP vault address. It's configured separately in:
- `manifests/core/external-secrets-operator/clustersecretstore-nas-vault-backend.yaml`

When changing the QNAP address, remember to update both locations.

### Future Improvement

Consider using a single source of truth by having ESO read the QNAP address from the same ConfigMap:

```yaml
spec:
  provider:
    vault:
      server:
        valueFrom:
          configMapKeyRef:
            name: nas-vault-config
            namespace: vault
            key: config.yaml
            # Extract just the address using JSONPath
```

However, ESO doesn't currently support this pattern for the server field.