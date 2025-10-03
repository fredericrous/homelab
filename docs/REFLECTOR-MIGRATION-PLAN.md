# Kubernetes Reflector Migration Plan

This document outlines the migration plan to introduce Kubernetes Reflector into the homelab to simplify secret management across namespaces.

## Overview

Kubernetes Reflector will eliminate the need for:
- Complex cross-namespace RBAC configurations
- Shell scripts that fetch secrets using curl and Kubernetes API
- Manual secret copying between namespaces
- Some ExternalSecrets that only exist to copy secrets

## Phase 1: Deploy Kubernetes Reflector (Non-Breaking)

### 1.1 Add Reflector to ArgoCD Applications

```yaml
# manifests/argocd/applications/kubernetes-reflector.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kubernetes-reflector
  namespace: argocd
spec:
  project: infrastructure
  source:
    repoURL: https://github.com/fredericrous/homelab
    targetRevision: main
    path: manifests/core/kubernetes-reflector
  destination:
    server: https://kubernetes.default.svc
    namespace: kubernetes-reflector
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

### 1.2 Deploy Reflector

1. Apply the Reflector manifests created earlier
2. Verify deployment: `kubectl get pods -n kubernetes-reflector`
3. Check logs: `kubectl logs -n kubernetes-reflector -l app.kubernetes.io/name=reflector`

## Phase 2: Add Reflector Annotations to Core Secrets (Non-Breaking)

### 2.1 Update vault-admin-token Secret

The vault-admin-token is created by the vault-init job. We need to patch the job to add reflector annotations:

```yaml
# manifests/core/vault/job-vault-init.yaml
# Add to the script section after creating the secret:
kubectl annotate secret vault-admin-token -n vault \
  "reflector.v1.k8s.emberstack.com/reflection-allowed=true" \
  "reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces=external-secrets,postgres,haproxy-controller,authelia,lldap,harbor,nextcloud,stremio" \
  "reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true" \
  --overwrite
```

### 2.2 Test Reflection

1. Check if secrets are reflected:
```bash
# After vault-init runs, check reflected secrets
kubectl get secret vault-admin-token -n external-secrets
kubectl get secret vault-admin-token -n postgres
```

## Phase 3: Migrate External Secrets Operator Configuration

### 3.1 Update ESO Configuration Job

1. Replace the complex job with the simplified version:
```bash
# Backup current configuration
cp manifests/core/external-secrets-operator/job-vault-configure-eso.yaml \
   manifests/core/external-secrets-operator/job-vault-configure-eso.yaml.bak

# Use the simplified version
cp manifests/core/external-secrets-operator/job-vault-configure-eso-simplified.yaml \
   manifests/core/external-secrets-operator/job-vault-configure-eso.yaml
```

2. Remove the RBAC configuration:
```bash
# Remove from kustomization.yaml
# - vault-token-reader-rbac.yaml
```

### 3.2 Test ESO Configuration

1. Delete and recreate the ESO job
2. Verify it completes successfully
3. Check ClusterSecretStore status

## Phase 4: Migrate Client CA Certificate

### 4.1 Update Post-Deployment Script

Update the script that creates client-ca-cert to add reflector annotations:

```bash
# terraform/scripts/post-deployment-fixes.sh
# Add after creating the secret:
kubectl annotate secret client-ca-cert -n vault \
  "reflector.v1.k8s.emberstack.com/reflection-allowed=true" \
  "reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces=haproxy-controller" \
  "reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true" \
  --overwrite
```

### 4.2 Remove ExternalSecret

1. Remove `client-ca-externalsecret.yaml` from haproxy-ingress
2. Update kustomization.yaml to remove the reference

## Phase 5: Migrate CloudNativePG Vault Token Access

### 5.1 Update populate-secrets Job

```yaml
# manifests/core/cloudnative-pg/job-populate-vault-secrets.yaml
# Simplify to use reflected secret directly
volumeMounts:
- name: vault-token
  mountPath: /vault-token
  readOnly: true
volumes:
- name: vault-token
  secret:
    secretName: vault-admin-token  # Reflected from vault namespace
```

### 5.2 Remove Cross-Namespace RBAC

1. Delete `vault-token-reader-rbac.yaml`
2. Update kustomization.yaml

## Phase 6: Update Application Jobs

### 6.1 Identify Jobs Using Cross-Namespace Access

```bash
# Find all jobs that fetch vault-admin-token
grep -r "kubectl get secret vault-admin-token" manifests/
grep -r "curl.*vault-admin-token" manifests/
```

### 6.2 Update Each Job

For each job found:
1. Remove the complex token fetching logic
2. Mount the reflected secret directly
3. Update service account (use default or app-specific, not cross-namespace ones)

## Phase 7: Cleanup Obsolete Resources

### 7.1 Remove Obsolete RBAC

```bash
# List all cross-namespace RBAC for vault token access
kubectl get rolebinding -A | grep vault-admin-token
kubectl get role -A | grep vault-admin-token-reader

# Delete them after confirming they're not needed
```

### 7.2 Remove Obsolete Service Accounts

```bash
# Find service accounts created just for cross-namespace access
kubectl get sa -A | grep -E "(vault-config|vault-secrets)"
```

### 7.3 Remove Obsolete Scripts

1. Remove complex shell scripts that fetch tokens
2. Simplify job configurations

## Phase 8: Add Reflector for Other Shared Secrets

### 8.1 PostgreSQL Superuser Secret

If needed in multiple namespaces, add reflector annotations:
```yaml
annotations:
  reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
  reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "nextcloud,authelia,harbor"
```

### 8.2 NAS Sync Secrets

For temporary secrets during NAS sync operations, use reflector to avoid complex mounting.

## Rollback Plan

If issues arise during migration:

1. **Phase 1-2**: Safe to rollback - just remove Reflector and annotations
2. **Phase 3+**: Keep backup files and restore original configurations
3. **Emergency**: Manually copy secrets to required namespaces as temporary fix

## Validation Checklist

- [ ] Reflector is deployed and running
- [ ] vault-admin-token is reflected to all required namespaces
- [ ] ESO configuration job completes successfully
- [ ] client-ca-cert is available in haproxy-controller
- [ ] All applications can access their required secrets
- [ ] No cross-namespace RBAC errors in logs
- [ ] ArgoCD shows all applications as healthy

## Benefits After Migration

1. **Reduced Complexity**: ~200+ lines of RBAC and scripts removed
2. **Faster Deployment**: No complex init containers or token fetching
3. **Better GitOps**: Declarative annotations instead of imperative scripts
4. **Easier Debugging**: Direct secret access, no cross-namespace permissions
5. **Improved Security**: Explicit control over which namespaces get secrets

## Next Steps

After successful migration:
1. Update CLAUDE.md with Reflector usage patterns
2. Document which secrets are reflected and why
3. Consider using Reflector for cert-manager certificates
4. Evaluate other shared resources (ConfigMaps) for reflection