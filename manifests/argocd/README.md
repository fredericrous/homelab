# Argo CD - GitOps for Homelab

This directory contains the Argo CD installation and configuration for the homelab Kubernetes cluster.

## Overview

Argo CD implements GitOps continuous delivery, automatically syncing the cluster state with this Git repository. It uses the **App of Apps** pattern with **ApplicationSets** for automatic application discovery.

### Architecture

1. **Bootstrap Process**: Manual one-time installation that hands control to Argo CD
2. **App of Apps**: Root application that discovers and creates all other applications
3. **ApplicationSets**: Automatically discover apps based on `app.yaml` files
4. **Projects**: RBAC boundaries separating core infrastructure from user apps

## Initial Bootstrap

To bootstrap Argo CD for the first time:

```bash
# From the manifests/argocd directory
kubectl apply -k .

# Monitor the bootstrap process
kubectl logs -n argocd job/argocd-bootstrap -f

# Check that applications are being discovered
kubectl get applications -n argocd
```

The bootstrap job will:
1. Wait for Argo CD to be ready
2. Create the root Application
3. Hand over control to GitOps

## Directory Structure

```
manifests/argocd/
├── namespace.yaml              # Namespace with security labels
├── values.yaml                 # Helm chart configuration
├── kustomization.yaml          # Main Kustomize file
├── bootstrap-job.yaml          # One-time bootstrap job
├── app-of-apps.yaml           # Root application
├── project-*.yaml             # AppProject definitions
├── app.yaml                   # Argo CD's own app descriptor
└── root/                      # ApplicationSets directory
    ├── kustomization.yaml
    ├── applicationset-core.yaml
    └── applicationset-apps.yaml
```

## Adding Applications

### Core Services (Infrastructure)

1. Create your app in `manifests/core/<app-name>/`
2. Add an `app.yaml` file:
   ```yaml
   name: my-service
   project: core
   namespace: my-namespace
   path: manifests/core/my-service
   syncWave: "-8"  # Optional, defaults to -10
   ```

### User Applications

1. Create your app in `manifests/apps/<app-name>/`
2. Add an `app.yaml` file:
   ```yaml
   name: my-app
   project: apps
   namespace: my-app  # Will be created automatically!
   path: manifests/apps/my-app
   syncWave: "15"  # Optional, defaults to 10
   # Optional: customize namespace pod security
   namespacePodSecurity:
     enforce: baseline  # Default: restricted
   # Optional: add namespace labels
   namespaceExtraLabels:
     team: backend
   ```

The namespace will be automatically created with:
- Proper security labels (pod security standards)
- Consistent labels for management
- Created before the app (sync wave -20)

## Sync Waves

Applications deploy in order based on sync waves:
- **Core services**: Negative waves (-11 to -1)
- **User applications**: Positive waves (1 to 20)

Common patterns:
- `-11`: Argo CD itself
- `-10`: Vault, cert-manager
- `-9`: MetalLB, storage operators
- `-8`: Databases, Redis
- `10`: User applications
- `15`: Applications with dependencies

## Access

### Web UI
- URL: https://argocd.daddyshome.fr
- Username: `admin`
- Password: Retrieved during bootstrap (see logs)

### CLI
```bash
# Install Argo CD CLI
brew install argocd  # or download from GitHub releases

# Login (uses gRPC-Web through HAProxy)
argocd login argocd.daddyshome.fr --grpc-web

# List applications
argocd app list

# Sync all applications
argocd app sync -l argocd.argoproj.io/instance=root
```

## Configuration

### Redis
Using Argo CD's built-in Redis due to Talos Linux security restrictions that prevent cross-namespace TCP connections with strict security contexts.

**Note on External Redis**: Even after fixing Cilium configuration, attempts to use external Redis (`redis-standalone.ot-operators.svc.cluster.local:6379`) fail with "operation not permitted" due to:
- Talos enforces pods with `capabilities.drop: ["ALL"]` which blocks raw socket operations
- The `argocd` namespace has `pod-security.kubernetes.io/enforce: restricted` which prevents adding network capabilities
- Adding `NET_RAW` capability violates the pod security standards

The built-in Redis is the recommended solution for Argo CD on Talos Linux with restricted pod security.

### Health Checks
Custom health checks are configured for:
- cert-manager Certificates
- Velero Backups
- Vault Static Secrets
- CloudNativePG Clusters
- Rook-Ceph Clusters

### RBAC
- Default policy: `role:readonly`
- Admin group: `argocd-admins`
- Projects enforce namespace boundaries

## Troubleshooting

### Applications stuck in "Progressing"
```bash
# Check application details
argocd app get <app-name>

# Force sync
argocd app sync <app-name> --force

# Check events
kubectl describe application <app-name> -n argocd
```

### Bootstrap job fails
```bash
# Check job logs
kubectl logs -n argocd job/argocd-bootstrap

# Delete and retry
kubectl delete job -n argocd argocd-bootstrap
kubectl apply -k .
```

### Custom resources not healthy
Check the health check configuration in `values.yaml` under `configs.cm.resource.customizations.health.*`

## Security Notes

- Initial admin password is not logged by default (set `PRINT_INITIAL_PASSWORD=true` in bootstrap job to enable)
- Projects use least-privilege RBAC
- Apps cannot create namespaces (managed by core project)
- TLS terminated at HAProxy, Argo CD runs HTTP internally

## LDAP Authentication

Argo CD is configured to use LLDAP for authentication via Dex. The setup includes:

### Configuration
- **LDAP Server**: `lldap.lldap.svc.cluster.local:3890`
- **Base DN**: `dc=daddyshome,dc=fr`
- **Admin Bind DN**: `uid=admin,ou=people,dc=daddyshome,dc=fr`

### Group Mappings
- `lldap_admin` → Argo CD admin role
- `lldap_user` → Argo CD readonly role

### Setup Instructions

1. Apply the configuration (includes Vault setup job):
   ```bash
   kubectl apply -k .
   ```

2. The `vault-configure-argocd` job will automatically:
   - Create LDAP bind password in Vault
   - Configure Vault policy for Argo CD
   - Set up Kubernetes auth role

3. Access Argo CD:
   - Navigate to https://argocd.daddyshome.fr
   - Click "Log in via LLDAP"
   - Use your LLDAP credentials

### Managing Access
1. Create users in LLDAP admin panel (http://lldap.daddyshome.fr)
2. Assign users to appropriate groups:
   - `lldap_admin` for administrators
   - `lldap_user` for read-only access

## Future Enhancements

- [x] LDAP integration with LLDAP
- [ ] OIDC integration with Authelia (when configured)
- [ ] Notifications (Slack/Discord)
- [ ] Image updater for automated container updates
- [ ] Metrics and monitoring dashboards