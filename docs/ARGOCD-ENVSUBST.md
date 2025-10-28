# ArgoCD Environment Substitution Plugin

> **Deprecated**: The platform now boots exclusively through the `./bootstrap` CLI and FluxCD. Keep this document only as historical context; new environments should follow the zero-touch flow described in `README.md`.

This document describes how to use environment variable substitution in ArgoCD applications to avoid hardcoding sensitive values in your GitOps repository.

## Overview

The ArgoCD envsubst plugin allows you to use environment variables in your Kubernetes manifests. Variables are substituted at the time ArgoCD generates the manifests, before applying them to the cluster.

## Installation

The plugin is installed as part of the ArgoCD configuration in `manifests/core/argocd-config/`. It consists of:

1. **ConfigMap** (`argocd-cmp-envsubst`) - Plugin configuration
2. **Deployment Patch** (`argocd-repo-server-patch.yaml`) - Adds the plugin as a sidecar
3. **Environment Variables** (`argocd-env-vars.yaml`) - Common variables available to all apps

## Usage

### Step 1: Enable the Plugin for Your Application

Create a `.argocd-envsubst` file in your application directory:

```bash
touch manifests/apps/myapp/.argocd-envsubst
```

This file triggers the plugin to process your manifests.

### Step 2: Use Variables in Your Manifests

Use the `${VAR_NAME}` syntax in your YAML files:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: myapp-config
data:
  database-host: ${POSTGRES_HOST}
  cluster-name: ${CLUSTER_NAME}
  replicas: ${REPLICAS:-3}  # Default value syntax
```

### Step 3: Configure ArgoCD Application

In your Application manifest, specify the plugin:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  source:
    plugin:
      name: envsubst
```

## Available Variables

### Global Variables

These variables are defined in `argocd-env-vars` ConfigMap:

- `CLUSTER_NAME` - Name of the cluster (homelab)
- `CLUSTER_DOMAIN` - Internal cluster domain (cluster.local)
- `EXTERNAL_DOMAIN` - External domain (daddyshome.fr)
- `STORAGE_CLASS_DEFAULT` - Default storage class (rook-cephfs)
- `STORAGE_CLASS_BLOCK` - Block storage class (rook-ceph-block)
- `VAULT_ADDR` - Vault service address
- `POSTGRES_HOST` - PostgreSQL cluster host
- Resource defaults (CPU/memory requests and limits)

### Adding New Variables

1. **For non-sensitive values**, add to the ConfigMap:

```bash
kubectl edit configmap argocd-env-vars -n argocd
```

2. **For sensitive values**, create a secret:

```bash
kubectl create secret generic argocd-env-secrets -n argocd \
  --from-literal=API_KEY=xxx \
  --from-literal=DB_PASSWORD=yyy
```

The plugin automatically loads both ConfigMaps and Secrets.

## Advanced Features

### Default Values

Use default values for optional variables:

```yaml
replicas: ${REPLICAS:-1}
memory: ${MEMORY_LIMIT:-512Mi}
```

### Raw YAML Support

The plugin can process raw YAML files without kustomization:

```bash
manifests/apps/myapp/
├── .argocd-envsubst
├── deployment.yaml
└── service.yaml
```

### Caching

The plugin caches processed manifests for 5 minutes (configurable via `ARGOCD_ENV_CACHE_TTL`).

## Best Practices

1. **Use Vault for Secrets**: For sensitive data, use Vault and VaultStaticSecret instead of environment variables
2. **Document Variables**: Keep a list of required variables in your app's README
3. **Use Defaults**: Provide sensible defaults for optional variables
4. **Test Locally**: Use `envsubst` command locally to test your templates:

```bash
export CLUSTER_NAME=test
envsubst < deployment.yaml
```

## Troubleshooting

### Check Plugin Logs

```bash
kubectl logs -n argocd deployment/argocd-repo-server -c envsubst-plugin
```

### Verify Variables Are Set

```bash
kubectl get configmap argocd-env-vars -n argocd -o yaml
kubectl get secret argocd-env-secrets -n argocd -o yaml
```

### Test Manifest Generation

```bash
# In the app directory with .argocd-envsubst file
kubectl exec -n argocd deployment/argocd-repo-server -c envsubst-plugin -- \
  /plugin/plugin.sh generate
```

## Example Applications

See `manifests/apps/envsubst-test/` for a complete example application using the plugin.

## Migration Guide

To migrate an existing application to use envsubst:

1. Identify hardcoded values that should be variables
2. Replace them with `${VAR_NAME}` syntax
3. Add the `.argocd-envsubst` file
4. Update the Application to use the plugin
5. Test the deployment

## Security Considerations

- Environment variables are visible in the plugin container
- Don't use for highly sensitive secrets (use Vault instead)
- Variables are substituted at manifest generation time
- The plugin runs with minimal permissions
