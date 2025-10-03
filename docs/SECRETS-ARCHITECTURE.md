# Secrets Architecture

## Current State
We're using Vault as the central secrets store with Vault Secrets Operator (VSO) to sync secrets to Kubernetes.

## Best Practices

### 1. No Cross-Namespace Secret Copying
**Problem**: Secret-copier jobs create circular dependencies and timing issues.

**Solution**: Each namespace should pull its own secrets directly from Vault using VSO.

### 2. Vault Path Convention
```
secret/
├── <service-name>/
│   ├── config        # Application configuration
│   ├── credentials   # Service credentials
│   └── api-keys     # External API keys
├── shared/
│   ├── ovh-dns      # Shared across multiple services
│   └── aws-creds
└── infrastructure/
    ├── database     # Database credentials
    └── backup       # Backup credentials
```

### 3. VSO Pattern for Each Service

```yaml
# Standard pattern for each namespace
apiVersion: v1
kind: ServiceAccount
metadata:
  name: <service-name>
  namespace: <namespace>
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata:
  name: <service-name>
  namespace: <namespace>
spec:
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: <service-name>
    serviceAccount: <service-name>
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: <secret-name>
  namespace: <namespace>
spec:
  type: kv-v2
  mount: secret
  path: <service-name>/<secret-name>
  destination:
    name: <secret-name>
    create: true
  refreshAfter: 30s
  vaultAuthRef: <service-name>
```

### 4. Vault Policy per Service

```hcl
# vault/policies/<service-name>.hcl
path "secret/data/<service-name>/*" {
  capabilities = ["read"]
}

# For shared secrets
path "secret/data/shared/ovh-dns" {
  capabilities = ["read"]
}
```

### 5. Bootstrap Secrets

For bootstrapping (before Vault is ready), use:

1. **Placeholder secrets** created by Terraform/Task
2. **Post-deployment jobs** to populate real values
3. **Health checks** that tolerate missing secrets during bootstrap

### 6. Secret Rotation

VSO handles rotation automatically:
- `refreshAfter: 30s` - Check for updates every 30 seconds
- `rolloutRestartTargets` - Restart pods when secrets change

### 7. Migration Path

1. **Phase 1**: Remove secret-copier jobs
2. **Phase 2**: Add VSO resources for each namespace
3. **Phase 3**: Update Vault policies
4. **Phase 4**: Remove manual secret creation from scripts

## Benefits

1. **No circular dependencies** - Each service is self-contained
2. **Better security** - Secrets never leave their namespace
3. **Easier debugging** - Clear ownership and audit trail
4. **GitOps friendly** - All configuration in Git
5. **Automatic rotation** - VSO handles updates
6. **Scalable** - Same pattern for all services

## Example: Cert-Manager

Before (problematic):
```
Vault → Secret-Copier Job → Cert-Manager Namespace
         (cross-namespace)
```

After (clean):
```
Vault ← VSO ← Cert-Manager Namespace
      (direct pull)
```

## Implementation Checklist

- [ ] Create Vault policies for each service
- [ ] Deploy VSO resources in each namespace
- [ ] Remove secret-copier jobs
- [ ] Update deployment documentation
- [ ] Test secret rotation
- [ ] Monitor VSO sync status