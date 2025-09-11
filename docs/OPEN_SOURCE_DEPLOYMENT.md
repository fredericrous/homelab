# Open Source Deployment Guide

This guide explains how to deploy this homelab while keeping your sensitive information (domains, IPs, tokens) private.

## Overview

This repository uses a template-based approach to keep sensitive data out of Git while maintaining a clean, open-source friendly codebase.

## Quick Start

### 1. Fork and Clone

```bash
git clone https://github.com/yourusername/homelab.git
cd homelab
```

### 2. Configure Environment

```bash
# Copy the example environment file
cp .env.example .env

# Edit with your values
nano .env
```

Key variables to set:
- `CLUSTER_DOMAIN`: Your domain (e.g., `homelab.local` or `yourdomain.com`)
- `QNAP_VAULT_ADDR`: Your NAS IP address
- `OVH_*`: Your DNS provider credentials (for Let's Encrypt)

### 3. Prepare Deployment

Run the preparation script to generate your local configurations:

```bash
./scripts/prepare-deployment.sh
```

This will:
- Create a `.build/` directory with your personalized manifests
- Replace all placeholder domains with your actual domain
- Substitute environment-specific values
- Keep everything out of Git

### 4. Deploy with ArgoCD

Option A: Point ArgoCD to the build directory
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  source:
    path: .build/core/vault  # Use build directory
```

Option B: Use a private values repository
1. Create a private Git repository for your values
2. Configure ArgoCD with multiple sources
3. Keep sensitive data completely separate

## Architecture

### Template System

1. **Templates (`*.tmpl`)**: Files with placeholders like `${CLUSTER_DOMAIN}`
2. **Examples (`*.example`)**: Sample configurations with dummy values
3. **Build Process**: Generates actual configs in `.build/` (gitignored)

### What's Templated

- **Ingress files**: Domain names
- **ConfigMaps**: Infrastructure addresses (NAS, Vault)
- **External Secrets**: Vault server addresses
- **Storage**: NFS server IPs

### What's NOT Templated

- **Application logic**: No changes needed
- **Service definitions**: Work as-is
- **RBAC**: Domain-agnostic

## Security Best Practices

### Never Commit

- `.env` file
- Actual ingress.yaml files (use .tmpl)
- ConfigMaps with real IPs
- Any file with your actual domain

### Always Use

- Environment variables for scripts
- Templates for Kubernetes manifests
- Example files for documentation
- Placeholders like `YOUR-NAS-IP`, `yourdomain.com`

## Alternative Approaches

### 1. Helm Values (Recommended for Teams)

Create a private Helm values repository:

```yaml
# values/production.yaml (private repo)
global:
  domain: myactual.domain
  vault:
    address: http://192.168.1.42:8200
```

### 2. Sealed Secrets

For credentials and tokens:
```bash
echo -n "my-secret-token" | kubeseal --raw --scope cluster-wide
```

### 3. External Secrets Operator

Store all config in Vault:
```bash
vault kv put secret/config domain=mydomain.com
```

### 4. GitOps with Private Overlay

```
manifests/
├── base/          # Public
└── overlays/
    └── private/   # Private repo
        └── kustomization.yaml
```

## Troubleshooting

### Domain Not Replaced

Check if the file has a `.tmpl` version:
```bash
find manifests -name "*.yaml" -exec grep -l "daddyshome.fr" {} \;
```

### Build Failed

Ensure all required environment variables are set:
```bash
./scripts/prepare-deployment.sh
```

### ArgoCD Can't Find Files

Make sure ArgoCD has access to the build directory or use multiple sources.

## Contributing

When contributing:

1. **Always use placeholders** for domains/IPs
2. **Create .tmpl files** for anything with environment-specific data
3. **Update .env.example** with new variables
4. **Document** any new configuration requirements

## Example PR

Good:
```yaml
# ingress.yaml.tmpl
host: vault.${CLUSTER_DOMAIN}
```

Bad:
```yaml
# ingress.yaml
host: vault.mydomain.com  # Don't commit real domains!
```