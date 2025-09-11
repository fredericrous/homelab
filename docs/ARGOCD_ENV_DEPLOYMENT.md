# ArgoCD Deployment with Environment Variables

This guide explains how to deploy the homelab using ArgoCD with environment variable substitution from your `.env` file.

## Overview

Instead of hardcoding sensitive values (domains, IPs) in manifests, we use environment variables that are:
1. Stored in your local `.env` file (not in Git)
2. Loaded into ArgoCD as a secret
3. Substituted at deploy time using a custom plugin

## Setup

### 1. Prerequisites

- Kubernetes cluster with ArgoCD installed
- `.env` file configured with your values
- `kubectl` access to the cluster

### 2. Configure ArgoCD Plugin

Apply the plugin configuration:

```bash
# Option 1: Dynamic plugin (recommended)
kubectl apply -f argocd/argocd-cm-envsubst-dynamic.yaml

# Option 2: Basic plugin with hardcoded variables
kubectl apply -f argocd/argocd-cm-envsubst-plugin.yaml
```

The dynamic plugin:
- Automatically detects which variables are used in your manifests
- Only substitutes variables that actually exist in the environment
- Warns about missing variables
- No hardcoded variable list needed!

### 3. Load Environment Variables into ArgoCD

Run the setup script to create a secret from your `.env`:

```bash
./argocd/setup-env-secret.sh
```

This will:
- Read your `.env` file
- Create a secret `argocd-env` in the `argocd` namespace
- Configure ArgoCD to use these environment variables

### 4. Deploy Using the Plugin

Option A: Update existing ApplicationSet
```bash
kubectl apply -f manifests/argocd/root/applicationset-core-envsubst.yaml
```

Option B: For testing, create a single app:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vault
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/yourusername/homelab
    targetRevision: main
    path: manifests/core/vault
    plugin:
      name: kustomize-envsubst
  destination:
    server: https://kubernetes.default.svc
    namespace: vault
```

## How It Works

1. **Manifests use placeholders**:
   ```yaml
   host: vault.${CLUSTER_DOMAIN}
   address: ${QNAP_VAULT_ADDR}
   ```

2. **ArgoCD loads your env vars** from the secret

3. **Plugin substitutes values** during sync:
   ```
   kustomize build . | envsubst
   ```

4. **Result**: Your actual values are used without being in Git

## Supported Variables

From your `.env` file:
- `${CLUSTER_DOMAIN}` - Base domain for all services
- `${QNAP_VAULT_ADDR}` - QNAP Vault URL
- `${NFS_SERVER}` - NFS server IP
- `${NFS_PATH}` - NFS share path
- `${LETSENCRYPT_EMAIL}` - Email for certificates
- `${OVH_APPLICATION_KEY}` - OVH API credentials
- `${OVH_APPLICATION_SECRET}`
- `${OVH_CONSUMER_KEY}`

## Updating Environment Variables

When you change values in `.env`:

1. Update the ArgoCD secret:
   ```bash
   ./argocd/setup-env-secret.sh
   ```

2. Restart ArgoCD repo server (or wait for automatic restart):
   ```bash
   kubectl rollout restart deployment/argocd-repo-server -n argocd
   ```

3. Refresh your applications in ArgoCD UI

## Security Considerations

- The `.env` file is never committed to Git
- Environment variables are stored as Kubernetes secrets
- Only ArgoCD repo server has access to these values
- Values are substituted at deploy time, not stored in Git

## Troubleshooting

### Variables not substituting

1. Check the secret exists:
   ```bash
   kubectl get secret argocd-env -n argocd
   ```

2. Verify repo server has env vars:
   ```bash
   kubectl exec -n argocd deployment/argocd-repo-server -- env | grep CLUSTER_DOMAIN
   ```

3. Check plugin is configured:
   ```bash
   kubectl get cm argocd-cm -n argocd -o yaml | grep kustomize-envsubst
   ```

### Debugging substitution

Test locally:
```bash
export $(cat .env | xargs)
kustomize build manifests/core/vault | envsubst
```

## For Open Source Users

When you open source your repo:

1. Your manifests contain placeholders like `${CLUSTER_DOMAIN}`
2. Users create their own `.env` file
3. They run the same setup process
4. Their values are substituted without touching the code

This keeps your repo clean and reusable!