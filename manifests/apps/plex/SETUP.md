# Plex Setup Guide

## Initial Setup

The Plex deployment is fully automated with one exception: the Plex claim token.

### Obtaining a Plex Claim Token

1. Visit https://www.plex.tv/claim/ (you must be logged in)
2. Copy the claim token (it's valid for 4 minutes)
3. Update it in Vault:

```bash
# Port-forward to Vault
kubectl port-forward -n vault svc/vault 8200:8200

# Set environment
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(kubectl get secret vault-admin-token -n vault -o jsonpath='{.data.token}' | base64 -d)

# Update the claim token
vault kv patch secret/plex/config claim_token="claim-XXXXXXXXXXXXXXXXXXXX"
```

4. Restart the Plex pod to pick up the new token:
```bash
kubectl rollout restart deployment plex -n plex
```

## Automated Setup

The following is handled automatically:

1. **Service Account Creation** - The `plex` service account is created automatically
2. **Vault Secret Population** - The `job-vault-populate-plex.yaml` creates placeholder secrets in Vault
3. **External Secrets Sync** - The `plex-config-externalsecret.yaml` syncs secrets from Vault to Kubernetes
4. **Volume Mounts** - NFS media volumes are automatically mounted

## Secret Structure in Vault

### `secret/plex/config`
- `claim_token`: Plex claim token (must be updated with real token)

### `secret/plex/preferences` (optional)
- `advertise_ip`: External URL for Plex
- `friendly_name`: Display name for the server
- `timezone`: Server timezone
- `allowed_networks`: Networks allowed to access without auth

## Troubleshooting

### Pod not starting
Check if the secret exists and has the correct key:
```bash
kubectl get secret plex-config -n plex -o yaml
```

### External Secret not syncing
Check the ExternalSecret status:
```bash
kubectl describe externalsecret plex-config -n plex
```

### Claim token expired
Claim tokens are only valid for 4 minutes. Get a new one from https://www.plex.tv/claim/