# Migration Guide: VSO to ESO

This guide helps you migrate from Vault Secrets Operator (VSO) to External Secrets Operator (ESO).

## Why Migrate?

- ESO has better ArgoCD integration (no Helm hook conflicts)
- More active development and community support
- Better CRD management
- Works well with GitOps workflows

## Key Differences

### 1. Resource Types
- VSO: `VaultStaticSecret` + `VaultAuth`
- ESO: `ExternalSecret` (uses ClusterSecretStore for auth)

### 2. Authentication
- VSO: Per-namespace `VaultAuth` resources
- ESO: Global `ClusterSecretStore` with Vault backend

### 3. Secret Refresh
- VSO: `refreshAfter` field
- ESO: `refreshInterval` field

## Migration Steps

### Step 1: Remove VSO Resources

Remove from your `kustomization.yaml`:
```yaml
# Remove these:
- ../../base/vault-auth
- vault-secret-sync.yaml
- ovh-credentials-vso.yaml
```

### Step 2: Create ExternalSecret

Replace `VaultStaticSecret` with `ExternalSecret`:

**Before (VSO):**
```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: lldap-secrets
  namespace: lldap
spec:
  vaultAuthRef: lldap-auth
  mount: secret
  type: kv-v2
  path: lldap
  destination:
    create: true
    name: lldap-secrets
  refreshAfter: 30s
  hmacSecretData: true
```

**After (ESO):**
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: lldap-secrets
  namespace: lldap
spec:
  refreshInterval: 5m  # ESO uses time duration format
  
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  
  target:
    name: lldap-secrets
    creationPolicy: Owner
    deletionPolicy: Retain
  
  # Fetch all keys from the Vault path
  dataFrom:
  - extract:
      key: secret/data/lldap
```

### Step 3: For Individual Keys

If you need specific keys (not all keys from a path):

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: ovh-credentials
  namespace: lldap
spec:
  refreshInterval: 30m
  
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  
  target:
    name: ovh-credentials
    creationPolicy: Owner
  
  data:
  - secretKey: application_key
    remoteRef:
      key: secret/data/ovh-dns
      property: application_key
  - secretKey: application_secret
    remoteRef:
      key: secret/data/ovh-dns
      property: application_secret
  - secretKey: consumer_key
    remoteRef:
      key: secret/data/ovh-dns
      property: consumer_key
```

### Step 4: Enable Auto-Reload (Optional)

Add Stakater Reloader annotations to your deployment:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lldap
  namespace: lldap
  annotations:
    # Option 1: Auto-reload on any secret/configmap change
    reloader.stakater.com/auto: "true"
    
    # Option 2: Explicitly specify which secrets to watch
    # secret.reloader.stakater.com/reload: "lldap-secrets,ovh-credentials"
spec:
  # ... rest of deployment
```

### Step 5: Clean Up Vault Configuration

The ESO uses a single Kubernetes auth path (`kubernetes-eso`) instead of per-app paths.
You can remove app-specific Vault configuration jobs.

## Complete Example

See `examples/lldap-migrated.yaml` for a complete migrated application.

## Troubleshooting

### Secret Not Syncing
1. Check ExternalSecret status:
   ```bash
   kubectl describe externalsecret -n <namespace> <name>
   ```

2. Verify ClusterSecretStore is ready:
   ```bash
   kubectl get clustersecretstore vault-backend -o yaml
   ```

3. Check ESO logs:
   ```bash
   kubectl logs -n external-secrets deployment/external-secrets
   ```

### Authentication Issues
- ESO uses the `external-secrets` service account in the `external-secrets` namespace
- Ensure Vault policy allows reading from your secret paths
- Check the ESO configuration job: `kubectl logs -n external-secrets job/vault-configure-eso`