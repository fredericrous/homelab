# Kubernetes Reflector Usage Guide

This document explains how Kubernetes Reflector is used in our homelab to simplify cross-namespace secret management.

## Prerequisites

Kubernetes Reflector must be deployed for cross-namespace secret sharing to work:
```bash
kubectl apply -k manifests/core/kubernetes-reflector/
```

## Overview

Kubernetes Reflector automatically replicates secrets and configmaps across namespaces based on annotations. This eliminates the need for complex RBAC configurations and manual secret copying.

## Key Benefits

1. **Simplified RBAC**: No more cross-namespace service accounts or complex role bindings
2. **Declarative Management**: Secret replication is defined through annotations
3. **Automatic Updates**: Changes to source secrets are automatically propagated
4. **GitOps Friendly**: All configuration is in YAML manifests

## Reflected Secrets

### vault-admin-token

The Vault admin token is reflected from the `vault` namespace to all namespaces that need Vault access:

**Source**: `vault/vault-admin-token`  
**Reflected to**:
- `external-secrets` - For ESO to authenticate with Vault
- `postgres` - For CloudNativePG jobs to populate secrets
- `haproxy-controller` - For HAProxy configuration from Vault
- `authelia` - For authentication configuration
- `lldap` - For LDAP configuration
- `harbor` - For registry configuration
- `nextcloud` - For application configuration
- `stremio` - For streaming service configuration
- `argocd` - For GitOps operations

**Annotations**:
```yaml
reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "external-secrets,postgres,haproxy-controller,authelia,lldap,harbor,nextcloud,stremio,argocd"
reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
```

### client-ca-cert

The client CA certificate for mTLS is reflected from `vault` to `haproxy-controller`:

**Source**: `vault/client-ca-cert`  
**Reflected to**:
- `haproxy-controller` - For mTLS client certificate validation

**Created by**: `terraform/scripts/post-deployment-fixes.sh`

## Adding New Namespaces

To add a new namespace to receive reflected secrets:

1. **Update VaultTransitUnseal CRD** in `manifests/core/vault/vault-transit-unseal.yaml`:
   ```yaml
   adminTokenAnnotations:
     reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "existing-namespaces,new-namespace"
   ```

2. **Apply the changes**:
   ```bash
   kubectl apply -k manifests/core/vault/
   ```

3. **Verify reflection**:
   ```bash
   kubectl get secret vault-admin-token -n new-namespace
   ```

## Creating New Reflected Secrets

To create a new secret that should be reflected:

1. **Create the secret with annotations**:
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: my-secret
     namespace: source-namespace
     annotations:
       reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
       reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "target-ns1,target-ns2"
       reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
   data:
     key: value
   ```

2. **Or add annotations to existing secrets**:
   ```bash
   kubectl annotate secret my-secret -n source-namespace \
     "reflector.v1.k8s.emberstack.com/reflection-allowed=true" \
     "reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces=target-ns1,target-ns2" \
     "reflector.v1.k8s.emberstack.com/reflection-auto-enabled=true"
   ```

## Monitoring Reflector

Check Reflector logs for any issues:
```bash
kubectl logs -n kubernetes-reflector -l app.kubernetes.io/name=reflector
```

View all reflected secrets:
```bash
kubectl get secrets -A -o json | jq '.items[] | select(.metadata.annotations["reflector.v1.k8s.emberstack.com/reflected-from"] != null) | {namespace: .metadata.namespace, name: .metadata.name, source: .metadata.annotations["reflector.v1.k8s.emberstack.com/reflected-from"]}'
```

## Troubleshooting

### Secret not reflected

1. **Check source secret annotations**:
   ```bash
   kubectl get secret <name> -n <source-namespace> -o yaml | grep -A5 annotations
   ```

2. **Verify target namespace is in allowed list**:
   - Check `reflection-allowed-namespaces` includes the target namespace

3. **Check Reflector logs**:
   ```bash
   kubectl logs -n kubernetes-reflector deployment/reflector
   ```

### Reflected secret outdated

Reflector should update reflected secrets within seconds. If not:

1. **Check Reflector is running**:
   ```bash
   kubectl get pods -n kubernetes-reflector
   ```

2. **Force update by modifying source**:
   ```bash
   kubectl annotate secret <name> -n <source-namespace> \
     "reflector.v1.k8s.emberstack.com/force-update=$(date +%s)" \
     --overwrite
   ```

## Migration from Cross-Namespace RBAC

We migrated from complex RBAC configurations to Reflector:

**Before** (Cross-namespace RBAC):
- Service accounts with cross-namespace permissions
- Complex RoleBindings and ClusterRoles
- Jobs using `kubectl` to fetch secrets from other namespaces
- Maintenance overhead for RBAC updates

**After** (Reflector):
- Simple annotations on source secrets
- Secrets automatically appear in target namespaces
- Jobs mount secrets directly from their own namespace
- Single point of configuration in source annotations

## Security Considerations

1. **Least Privilege**: Only reflect secrets to namespaces that need them
2. **Audit Trail**: All reflections are logged by Reflector
3. **Source Control**: Annotations define which namespaces can receive secrets
4. **No Wildcards**: Explicitly list allowed namespaces (no wildcard support)

## Best Practices

1. **Document reflected secrets** in this file when adding new ones
2. **Use descriptive secret names** that indicate their purpose
3. **Regularly audit** reflected secrets and their target namespaces
4. **Keep allowed namespace lists** as small as possible
5. **Monitor Reflector logs** for any issues or unauthorized access attempts