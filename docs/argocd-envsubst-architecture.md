# ArgoCD Envsubst Plugin - Simple Architecture

## The Problem

When using GitOps with ArgoCD, all configuration must be in Git. But you don't want to commit private values like:
- Your domain name (`daddyshome.fr`)
- Infrastructure IPs (`192.168.1.42`)
- Network configurations
- Cluster-specific values

## The Solution

The envsubst plugin allows you to use variables (`${ARGO_EXTERNAL_DOMAIN}`) in your manifests, with actual values provided at deployment time from your local `.env` file.

## How It Works

```
┌──────────┐      ┌─────────────┐      ┌──────────┐      ┌────────────┐
│   .env   │ ───► │ task deploy │ ───► │ConfigMap │ ───► │   Plugin   │
│ (local)  │      │             │      │(dynamic) │      │(substitute)│
└──────────┘      └─────────────┘      └──────────┘      └────────────┘
                                                                  │
                                                                  ▼
                                                          ┌────────────┐
                                                          │ Manifests  │
                                                          │(populated) │
                                                          └────────────┘
```

1. **Local `.env`** contains your private values (never committed)
2. **`task deploy`** creates a ConfigMap from `.env` dynamically
3. **Plugin** reads ConfigMap and substitutes variables
4. **Result**: Manifests with real values, but secrets stay local

## Key Design Principles

### 1. ConfigMap is Dynamic
- Created by `task deploy`, NOT from Git
- This is critical - the ConfigMap definition is NOT in your Git repo
- Only the ConfigMap reference in Helm values is in Git

### 2. Simple by Design
- One source of truth: ConfigMap
- No external dependencies (no Git repos, no Vault for bootstrap)
- No network calls during manifest generation
- Fast and reliable

### 3. GitOps Compatible
- ArgoCD sees manifests with variables
- Plugin substitutes at generation time
- Private values never touch Git

## Configuration

### In Your Manifests

Use variables with `${VARIABLE_NAME}` syntax:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-config
data:
  external-domain: ${ARGO_EXTERNAL_DOMAIN}
  vault-address: ${ARGO_NAS_VAULT_ADDR}
  cluster-name: ${ARGO_CLUSTER_NAME}
```

### In ArgoCD Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  source:
    plugin:
      name: envsubst
```

### During Deployment

The ConfigMap is created automatically by:

```bash
task deploy
```

This reads your `.env` file and creates:

```bash
kubectl create configmap argocd-envsubst-values \
  --namespace argocd \
  --from-file=values=/tmp/argo-values.env
```

## Why This Architecture?

1. **Privacy**: Your domain and IPs stay out of Git
2. **Simplicity**: One mechanism, no complex dependencies
3. **Reliability**: No external services needed for bootstrap
4. **Speed**: No network calls, just local file reads
5. **GitOps**: Everything except values is in Git

## Common Questions

**Q: Why not store values in Vault?**  
A: Bootstrap problem - you need these values to configure Vault itself.

**Q: Why not use a separate Git repo?**  
A: That just moves the problem - values would still be in Git.

**Q: Why not use Helm values?**  
A: Helm values would need to be in Git too.

**Q: Is the ConfigMap persistent?**  
A: Yes, it survives pod restarts. Recreated on cluster rebuild via `task deploy`.

## Best Practices

1. **Prefix variables** with `ARGO_` to avoid conflicts
2. **Document variables** in your manifests with comments
3. **Keep `.env` backed up** - it's your source of truth
4. **Never commit `.env`** - it's in `.gitignore` for a reason

## Troubleshooting

Check if ConfigMap exists:
```bash
kubectl get configmap argocd-envsubst-values -n argocd -o yaml
```

View plugin logs:
```bash
kubectl logs -n argocd deployment/argocd-repo-server -c envsubst
```

Test substitution locally:
```bash
cat manifest.yaml | envsubst
```

## Summary

This plugin solves one specific problem: keeping private values out of Git while using GitOps. It does this in the simplest way possible - a dynamically created ConfigMap. No fancy features, no external dependencies, just reliable environment variable substitution.