# Kubernetes Manifests

This directory contains all Kubernetes manifests for the homelab cluster, organized by type and purpose.

## Directory Structure

```
manifests/
├── base/           # Shared reusable configurations
├── core/           # Core infrastructure services
├── apps/           # User-facing applications
└── overlays/       # Environment-specific customizations (if needed)
```

### Base Directory (`base/`)
Contains reusable Kustomize bases that multiple services use:
- **vault-auth/** - Vault authentication setup (VaultAuth, ServiceAccount, RBAC)
- **job-templates/** - Reusable job patterns (vault-configure, vault-populate)
- **backup/** - Velero backup annotations
- **ingress/** - Common ingress configurations
- **security/** - Network policies and security contexts
- **volume-mounts/** - SMB volume templates
- **database-init/** - PostgreSQL initialization patterns

### Core Services (`core/`)
Essential infrastructure that other services depend on:
- **vault/** - Secrets management
- **vault-secrets-operator/** - Kubernetes secrets operator
- **cert-manager/** - Certificate management
- **cilium/** - CNI (Container Network Interface)
- **haproxy-ingress/** - Main ingress controller
- **haproxy-mobile/** - Mobile-specific ingress
- **metallb/** - Load balancer for bare metal
- **rook-ceph/** - Distributed storage
- **smb-csi-driver/** - SMB storage driver
- **cloudnative-pg/** - PostgreSQL operator
- **redis/** - In-memory data store
- **backup/** - Velero backup solution
- **node-feature-discovery/** - Node labeling
- **nvidia-device-plugin/** - GPU support
- **client-ca/** - Client certificate authority
- **coredns/** - DNS server customizations

### Applications (`apps/`)
User-facing services:
- **authelia/** - Authentication portal
- **harbor/** - Container registry
- **lldap/** - Lightweight LDAP server
- **nextcloud/** - File sharing and collaboration
- **plex/** - Media server
- **stremio/** - Media streaming
- **maddy/** - Mail server

## Deployment Order

Due to dependencies, services should be deployed in this order:

1. **Core Infrastructure**
   ```bash
   kubectl apply -k core/vault
   kubectl apply -k core/vault-secrets-operator
   kubectl apply -k core/cert-manager --enable-helm
   kubectl apply -k core/metallb
   kubectl apply -k core/cilium --enable-helm
   kubectl apply -k core/haproxy-ingress --enable-helm
   ```

2. **Storage**
   ```bash
   kubectl apply -k core/rook-ceph
   kubectl apply -k core/smb-csi-driver
   ```

3. **Database**
   ```bash
   kubectl apply -k core/cloudnative-pg
   kubectl apply -k core/redis
   ```

4. **Supporting Services**
   ```bash
   kubectl apply -k core/backup/base --enable-helm
   kubectl apply -k core/client-ca
   ```

5. **Applications** (can be deployed in any order)
   ```bash
   kubectl apply -k apps/lldap
   kubectl apply -k apps/authelia
   kubectl apply -k apps/harbor --enable-helm
   kubectl apply -k apps/nextcloud
   kubectl apply -k apps/plex
   kubectl apply -k apps/stremio
   ```

## Common Tasks

### Deploy a Service
```bash
kubectl apply -k <service-path> [--enable-helm]
```

### Check Service Status
```bash
kubectl get pods,svc,ingress -n <namespace>
```

### Force Secret Refresh (VSO)
```bash
kubectl patch vaultstaticsecret <name> -n <namespace> --type merge -p '{"spec":{"refreshAfter":"1s"}}'
```

### Validate Kustomization
```bash
kubectl kustomize <service-path> [--enable-helm]
```

## Using Shared Bases

Services use shared bases to reduce duplication. Example:

```yaml
# apps/myapp/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: myapp

resources:
  - ../../base/vault-auth      # Vault authentication
  - ../../base/job-templates   # Job templates
  - namespace.yaml
  - deployment.yaml
  - service.yaml

patches:
  # Customize vault auth
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

## Notes

- Services in `core/` use `../../base/` for base references
- Services in `apps/` use `../../base/` for base references
- The special case `core/backup/base/` uses `../../../base/`
- Some services require `--enable-helm` flag when they include Helm charts
- All services follow GitOps principles - no manual configuration required

## Harbor Registry Configuration

The cluster uses Harbor as the private container registry. Registry credentials are managed post-bootstrap:

1. **Initial Bootstrap**: Cluster starts without registry configuration
2. **Harbor Deployment**: Deploy Harbor application with credentials stored in Vault
3. **Registry Configuration**: A Kubernetes job configures containerd on all nodes with registry credentials
4. **Applications**: Use imagePullSecrets referencing Vault-synced secrets

This approach avoids hardcoding credentials in Talos machine configs.