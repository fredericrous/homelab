# Kustomize Base Templates

This directory contains reusable Kustomize bases to reduce duplication across services.

## Available Bases

### 1. vault-auth
Standard Vault authentication setup for services.

**Usage:**
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
        namespace: myapp
      spec:
        kubernetes:
          role: myapp
          serviceAccount: myapp
```

### 2. job-templates
Reusable job patterns for common tasks.

#### vault-configure job
```yaml
resources:
  - ../base/job-templates

patches:
  - target:
      kind: Job
      name: vault-configure-PLACEHOLDER
    patch: |-
      apiVersion: batch/v1
      kind: Job
      metadata:
        name: vault-configure-myapp
        namespace: myapp
      spec:
        template:
          spec:
            containers:
            - name: vault-configure
              command:
              - sh
              - -c
              - |
                # ... existing boilerplate ...
                
                # Replace PLACEHOLDER with actual app name
                vault policy write myapp - <<EOF
                path "secret/data/myapp/*" {
                  capabilities = ["read"]
                }
                EOF
                
                vault write auth/kubernetes/role/myapp \
                  bound_service_account_names=myapp \
                  bound_service_account_namespaces=myapp \
                  policies=myapp \
                  ttl=24h
```

### 3. volume-mounts
Standard SMB volume configurations.

**Usage:**
```yaml
resources:
  - ../base/volume-mounts

patches:
  - target:
      kind: PersistentVolumeClaim
      name: pvc-smb-PLACEHOLDER
    patch: |-
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: pvc-smb-myapp
        namespace: myapp
```

### 4. database-init
PostgreSQL database initialization patterns.

**Usage:**
```yaml
resources:
  - ../base/database-init
  - ../base/job-templates

patches:
  - target:
      kind: Job
      name: db-init-PLACEHOLDER
    patch: |-
      apiVersion: batch/v1
      kind: Job
      metadata:
        name: db-init-myapp
        namespace: myapp
      spec:
        template:
          spec:
            containers:
            - name: db-init
              env:
              - name: PGHOST
                value: postgres-cluster-rw.cloudnative-pg.svc.cluster.local
              - name: DB_NAME
                value: myapp_db
              - name: DB_USER
                valueFrom:
                  secretKeyRef:
                    name: myapp-db-credentials
                    key: username
```

### 5. backup
Velero backup annotations.

**Usage:**
```yaml
resources:
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
              backup.velero.io/backup-volumes: config,data
```

### 6. ingress
Common ingress configurations.

**Usage:**
```yaml
resources:
  - ../base/ingress
  - ingress.yaml

configMapGenerator:
  - name: ingress-annotations
    behavior: merge
    literals:
      - haproxy.org/server-ssl: "true"
      - haproxy.org/ssl-redirect: "true"
```

### 7. security
Network policies and security contexts.

**Usage:**
```yaml
resources:
  - ../base/security

# This provides:
# - Default deny-all network policy
# - Allow DNS, Vault, and ingress traffic
# - Non-root security context patches
```

## Pattern Examples

### Complete Service Setup

```yaml
# myapp/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: myapp

resources:
  # Base resources
  - ../base/vault-auth
  - ../base/security
  - ../base/volume-mounts
  - ../base/job-templates
  
  # App-specific resources
  - namespace.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
  - job-vault-configure-myapp.yaml

patches:
  # Customize vault auth
  - target:
      kind: VaultAuth
      name: vault-auth
    patch: |-
      # ... app-specific vault auth config
  
  # Add SMB volume
  - target:
      kind: Deployment
      name: myapp
    path: ../base/volume-mounts/deployment-smb-volume-patch.yaml
  
  # Add backup annotations
  - target:
      kind: Deployment
      name: myapp
    patch: |-
      # ... backup annotations
```

## Benefits

1. **DRY Principle**: No duplication of common patterns
2. **Consistency**: All services use the same base configurations
3. **Maintainability**: Update once, apply everywhere
4. **GitOps**: Everything is declarative and version controlled
5. **Flexibility**: Services can override or extend base configurations