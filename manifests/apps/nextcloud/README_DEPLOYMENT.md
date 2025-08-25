# Nextcloud Deployment Notes

## Deployment

The deployment includes everything needed, including database initialization:

```bash
# Ensure the postgres superuser password is in Vault at secret/postgres/superuser
# Then deploy Nextcloud
kubectl apply -k .
```

The deployment includes:
- Vault secrets initialization job (creates secrets if missing, skips if they exist)
- Database creation job (idempotent - safe to run multiple times)
- Postgres superuser secret from Vault
- All Nextcloud resources and configuration jobs

## Features

1. **Mobile Access**:
   - The `ingress-mobile.yaml` is already included in kustomization.yaml
   - It provides access via `drive-mobile.daddyshome.fr` without mTLS for mobile apps
   - Main ingress at `drive.daddyshome.fr` requires client certificates

3. **GPU Support** (when GPU node is fixed):
   - Uncomment the GPU patch in `kustomization.yaml`:
     ```yaml
     patches:
       # ... other patches ...
       - path: patch-gpu-runtime.yaml
         target:
           kind: Deployment
           name: nextcloud
     ```
   - This enables GPU acceleration for video transcoding

## Notes

### Force Recreate Vault Secrets
If you need to force regenerate the Nextcloud passwords in Vault:
```bash
# Delete the existing secret from Vault
kubectl exec -n vault vault-0 -- vault kv delete secret/nextcloud

# Delete and recreate the job
kubectl delete job vault-populate-nextcloud-secrets -n nextcloud
kubectl apply -k .
```