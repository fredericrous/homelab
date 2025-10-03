# Migration Guide: From app-setup to Declarative Database Management

## Overview

This guide explains how to migrate from the current `app-setup` chart pattern to a fully declarative approach using:
- External Secrets Operator (ESO) Password Generator
- CloudNativePG Database CRD
- Declarative role management

## Current State (app-setup pattern)

The current pattern uses:
1. Helm chart `app-setup` with Jobs
2. Vault for password generation via `__GENERATE_PASSWORD__`
3. Shell scripts to create databases and users
4. Init containers to fetch credentials

## Target State (Declarative pattern)

The new pattern uses:
1. ESO Password Generator for secret generation
2. ESO PushSecret to sync to Vault (for compatibility)
3. CloudNativePG Database CRD for database creation
4. Cluster-level role management in CloudNativePG
5. Reflector for cross-namespace secret synchronization

## Benefits

1. **No Jobs**: Everything is reconciled continuously
2. **GitOps Native**: Pure declarative state
3. **Idempotent**: Can be applied multiple times safely
4. **Self-healing**: Automatically fixes drift
5. **Auditable**: All changes tracked in Git

## Migration Steps

### Step 1: Update CloudNativePG Cluster

Add role management to your PostgreSQL cluster:

```yaml
spec:
  managed:
    roles:
    - name: myapp
      ensure: present
      login: true
      passwordSecret:
        name: myapp-db-credentials
```

### Step 2: Create Password Generator

Create a password generator in your app namespace:

```yaml
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata:
  name: myapp-passwords
  namespace: myapp
spec:
  length: 32
  digits: 5
  symbols: 5
```

### Step 3: Create ExternalSecret with Generator

Generate passwords and push to Vault:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: myapp-generated
  namespace: myapp
spec:
  refreshInterval: 0  # Generate once
  target:
    name: myapp-passwords
  dataFrom:
  - sourceRef:
      generatorRef:
        kind: Password
        name: myapp-passwords
```

### Step 4: Create Database Resource

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: myapp
  namespace: myapp
spec:
  name: myapp
  owner: myapp
  cluster:
    name: postgres-apps
    namespace: postgres
```

### Step 5: Setup Secret Reflection

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: myapp-db-credentials
  namespace: myapp
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "postgres"
```

## Example: LLDAP Migration

1. **Remove** from `lldap-setup.yaml`:
   - The entire HelmRelease using app-setup

2. **Add** to `lldap/kustomization.yaml`:
   ```yaml
   resources:
     - password-generator.yaml
     - database.yaml
   ```

3. **Update** postgres cluster with lldap role

4. **Apply** the changes and verify

## Verification

```bash
# Check if passwords were generated
kubectl get secret -n lldap lldap-generated-passwords -o yaml

# Check if database was created
kubectl get database -n lldap

# Check postgres cluster for role
kubectl get cluster -n postgres postgres-apps -o yaml | grep -A10 "roles:"

# Verify in PostgreSQL
kubectl exec -n postgres postgres-apps-1 -- psql -U postgres -c "\du lldap"
kubectl exec -n postgres postgres-apps-1 -- psql -U postgres -c "\l lldap"
```

## Rollback Plan

If issues occur:
1. Keep the app-setup HelmRelease disabled but not deleted
2. The Database CRD won't delete existing databases
3. Passwords in Vault remain unchanged
4. Can re-enable app-setup HelmRelease if needed

## Known Limitations

1. **Role Management**: Requires modifying the central Cluster resource
2. **Cross-namespace**: Requires Reflector or complex RBAC
3. **Bootstrap Order**: Database CRD needs role to exist first
4. **Password Rotation**: Requires careful coordination

## Future Improvements

1. CloudNativePG may add a Role CRD in future versions
2. ESO may add native cross-namespace support
3. Consider using Crossplane for more complex scenarios