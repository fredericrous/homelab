# Vault Configuration Guide

## QNAP Transit Vault Address Configuration

The QNAP vault address is configured in `qnap-vault-config.yaml` ConfigMap.

### Current Configuration
- **Address**: `http://192.168.1.42:61200`
- **Mount Path**: `transit`
- **Key Name**: `autounseal`

### To Change the QNAP Vault Address

1. Edit `qnap-vault-config.yaml`:
```yaml
data:
  config.yaml: |
    transit:
      address: "http://NEW-IP:61200"
```

2. Commit and push the change
3. ArgoCD will automatically sync the updated configuration

### Why Not Use Environment Variables?

ArgoCD operates on Git repositories and doesn't have access to local environment variables. While ArgoCD supports parameters and plugins, using them with ApplicationSets adds unnecessary complexity for a value that rarely changes.

### Alternative Approaches (Not Recommended for Homelab)

1. **ArgoCD Vault Plugin**: Could template values from Vault itself
2. **Helm with ArgoCD**: Use Helm values with ArgoCD parameters
3. **Multiple Overlays**: Create dev/prod overlays with different configs

For a homelab, the static ConfigMap is the most maintainable approach.

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
            name: qnap-vault-config
            namespace: vault
            key: config.yaml
            # Extract just the address using JSONPath
```

However, ESO doesn't currently support this pattern for the server field.