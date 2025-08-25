# Shared Base Configurations

This directory contains reusable base configurations to reduce duplication across apps.

## Available Bases

### 1. vault-auth
Provides common Vault authentication setup:
- VaultConnection to Vault service
- VaultAuth template (needs patching with app-specific values)
- ServiceAccount for vault configuration jobs
- RBAC template for reading vault-admin-token

**Usage example:**
```yaml
resources:
  - ../base/vault-auth

patches:
  - target:
      kind: VaultAuth
      name: vault-auth
    patch: |-
      apiVersion: secrets.hashicorp.com/v1beta1
      kind: VaultAuth
      metadata:
        name: myapp-auth
      spec:
        kubernetes:
          role: myapp
          serviceAccount: myapp
```

### 2. backup
Provides Velero backup annotations for Deployments and StatefulSets.

**Usage example:**
```yaml
bases:
  - ../base/backup

patches:
  - target:
      kind: Deployment
      name: myapp
    patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: myapp
      spec:
        template:
          metadata:
            annotations:
              backup.velero.io/backup-volumes: myapp-data
```

### 3. ingress
Provides common ingress annotations for HAProxy and cert-manager.

**Usage example:**
```yaml
bases:
  - ../base/ingress

# Your ingress will automatically get common security headers and cert-manager annotations
```

### 4. security
Provides:
- Default network policies (deny all, allow DNS, allow ingress controller, allow Vault)
- Security context patches for pods

**Usage example:**
```yaml
resources:
  - ../base/security

# This will apply network policies and security contexts to your namespace
```

## Migration Guide

To migrate an existing app to use these bases:

1. Remove duplicate files:
   - `vault-connection.yaml` (provided by vault-auth base)
   - `patch-velero-backup.yaml` (provided by backup base)

2. Update kustomization.yaml to:
   - Include the relevant bases
   - Add patches to customize the templates

3. Test with: `kubectl kustomize . | kubectl diff -f -`

## Benefits

- **Less duplication**: Common patterns are defined once
- **Consistency**: All apps use the same configurations
- **Easier updates**: Update the base to affect all apps
- **Cleaner app directories**: Focus on app-specific configurations