# Harbor Registry Configuration

This directory contains the Harbor container registry deployment with post-bootstrap registry configuration.

## Overview

Instead of hardcoding registry credentials in Talos machine configs, we configure the registry after the cluster is up:

1. **Bootstrap**: Cluster starts without any registry configuration
2. **Vault Setup**: Harbor credentials are stored in Vault at `secret/harbor/registry`
3. **Harbor Deployment**: Harbor is deployed with auto-generated TLS certificates
4. **Registry Configuration**: A DaemonSet configures containerd on all nodes

## Key Components

### Secrets Management
- `harbor-vault-populate-job.yaml`: Populates initial secrets in Vault
- `harbor-registry-vault-secret.yaml`: Syncs registry credentials from Vault to K8s secret
- Credentials:
  - Username: `harbor_registry_user`
  - Password: Stored in Vault at `secret/harbor/registry/password`

### Registry Configuration
- `harbor-registry-config-job.yaml`: DaemonSet that:
  - Waits for Harbor to be ready
  - Extracts credentials from Vault-synced secret
  - Extracts CA certificate from Harbor's auto-generated certs
  - Configures containerd on each node with:
    - Registry mirrors for all Harbor endpoints
    - Basic auth credentials
    - CA certificate for TLS verification
  - Reloads containerd without disrupting running containers

### TLS Configuration
- Harbor uses `certSource: auto` to generate its own certificates
- The registry config job extracts the CA from these certificates
- No manual certificate management required

## Deployment

```bash
# Deploy Harbor (assumes Vault is already set up)
kubectl apply -k manifests/apps/harbor --enable-helm

# The registry configuration DaemonSet will automatically:
# 1. Wait for Harbor to be ready
# 2. Configure all nodes with registry access
# 3. No restart required - uses containerd reload
```

## Benefits

- No hardcoded credentials in git
- Registry can be reconfigured without rebuilding Talos
- Credentials managed through Vault
- Automatic node configuration via DaemonSet
- Zero downtime - containerd reload instead of restart