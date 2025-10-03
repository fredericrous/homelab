# Environment Configuration

This homelab repository is designed to be fully open-source while keeping environment-specific values (IPs, domains, etc.) separate.

## Architecture

1. **Public Repository** (`fredericrous/homelab`): Contains all manifests with placeholders like `${ARGO_NAS_VAULT_ADDR}`
2. **Local Environment File**: Your `.env` file with actual values (never committed to Git)
3. **ConfigMap Bootstrap**: Terraform creates a ConfigMap in ArgoCD namespace from your `.env` file
4. **ArgoCD Plugin**: The envsubst plugin reads from the ConfigMap and substitutes placeholders

## Initial Setup

### 1. Clone Repository

```bash
# Clone the public homelab repository
git clone https://github.com/fredericrous/homelab
cd homelab
```

### 2. Configure Your Environment

```bash
# Copy the example environment file
cp .env.example .env

# Edit with your values
vim .env
```

### 3. Deploy

The deployment process automatically handles the environment configuration:

```bash
# This will:
# 1. Deploy the cluster
# 2. Create the values ConfigMap during ArgoCD installation (Stage 5)
task deploy
```

## How It Works

### During Deployment

1. Terraform reads your local `.env` file and filters `ARGO_*` prefixed variables
2. Stage 5 of deployment creates a ConfigMap from filtered variables:
   ```bash
   kubectl create configmap argocd-envsubst-values \
     --namespace argocd \
     --from-file=values="/tmp/argo-values.env"
   ```
3. The ArgoCD envsubst plugin mounts this ConfigMap at `/envsubst-values/values`
4. When processing manifests, the plugin loads these values as environment variables
5. All `${VARIABLE}` placeholders are replaced with actual values

### Resilience with ExternalSecret Fallback

To protect against etcd failures or ConfigMap loss:

1. **After initial deployment**, backup values to Vault:
   ```bash
   ./scripts/backup-argocd-values-to-vault.sh
   ```

2. **External Secrets Operator** syncs from Vault to a Secret:
   - ExternalSecret: `argocd-envsubst-values-external`
   - Target Secret: `argocd-envsubst-values-external`
   - Vault path: `secret/argocd/env-values`

3. **Plugin fallback order**:
   - Primary: ConfigMap `argocd-envsubst-values`
   - Fallback: Secret `argocd-envsubst-values-external`
   - If both exist, values are merged (Secret overrides ConfigMap)

This ensures your environment configuration survives even if etcd is restored from an old backup.

### For Updates

When you need to change environment values:

```bash
# Edit your local .env
vim .env

# Recreate the ConfigMap
cd terraform
terraform apply -target=null_resource.argocd_install

# Restart ArgoCD repo-server to pick up changes
kubectl rollout restart deployment/argocd-repo-server -n argocd

# (Optional) Backup to Vault for resilience
./scripts/backup-argocd-values-to-vault.sh
```

## Variable Naming Convention

Variables in `.env` follow a prefix convention:

- **`ARGO_*`** - Variables exposed to ArgoCD for manifest templating
- **No prefix** - Local variables used by scripts but not exposed to ArgoCD

This separation ensures:
- Only necessary configuration is exposed to ArgoCD
- Sensitive credentials stay in Vault (accessed via ESO)
- Clear distinction between deployment config and runtime secrets

## Supported Variables

### ArgoCD Variables (manifest templating)

| Variable | Description | Example |
|----------|-------------|---------|
| `ARGO_NAS_VAULT_ADDR` | NAS Vault address | `http://192.168.1.42:61200` |
| `ARGO_EXTERNAL_DOMAIN` | External domain | `example.com` |
| `ARGO_CLUSTER_NAME` | Cluster name | `homelab` |
| `ARGO_CLUSTER_DOMAIN` | Cluster domain | `cluster.local` |

### Local Variables (scripts only)

| Variable | Description | Example |
|----------|-------------|---------|
| `QNAP_VAULT_ADDR` | QNAP Vault address for scripts | `http://192.168.1.42:61200` |
| `QNAP_VAULT_TOKEN` | QNAP Vault auth token | `hvs.xxxxx` |
| `OVH_APPLICATION_KEY` | OVH API key (stored in Vault) | `your-key` |
| `OVH_APPLICATION_SECRET` | OVH API secret (stored in Vault) | `your-secret` |
| `OVH_CONSUMER_KEY` | OVH consumer key (stored in Vault) | `your-consumer-key` |

## Adding New Variables

1. Add to `.env` with ARGO_ prefix:
   ```bash
   ARGO_NEW_VARIABLE=value
   ```

2. Use in manifests:
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: example
   data:
     value: "${ARGO_NEW_VARIABLE}"
   ```

3. Enable plugin for the app in `app.yaml`:
   ```yaml
   name: myapp
   plugin: envsubst
   ```

4. The plugin will automatically use these values during manifest generation

## Security Considerations

- **Never commit `.env` to any repository** (it's in `.gitignore`)
- Keep your `.env` file local and secure
- The ConfigMap is created in `argocd` namespace with cluster access
- For truly sensitive data (passwords, API keys), use Vault instead
- The plugin only substitutes variables, it doesn't execute code

### Local File Security

- Keep your `.env` file permissions restrictive: `chmod 600 .env`
- Never share or commit the `.env` file
- Store backups securely (e.g., encrypted password manager)
- Rotate sensitive values periodically

## Troubleshooting

### Values not being substituted

1. Check the ConfigMap exists:
   ```bash
   kubectl get configmap argocd-envsubst-values -n argocd
   ```

2. Check plugin logs:
   ```bash
   kubectl logs -n argocd deployment/argocd-repo-server -c envsubst-plugin
   ```

3. Ensure the app has `plugin: envsubst` in its `app.yaml`

### ConfigMap out of sync

```bash
# Recreate from current .env
task update-values
```

### Plugin not loading values

Check the plugin container has the ConfigMap mounted:
```bash
kubectl describe deployment argocd-repo-server -n argocd | grep -A5 envsubst-values
```

## Migration from Static Values

If you're migrating from hardcoded values:

1. Identify all hardcoded IPs, domains, etc. in manifests
2. Replace with `${VARIABLE_NAME}` placeholders
3. Add `plugin: envsubst` to the app's `app.yaml`
4. Add the variables to your `.env` file
5. Run `task sync-env` and `task update-values`

Example:
```yaml
# Before
server: "http://192.168.1.42:61200"

# After
server: "${ARGO_NAS_VAULT_ADDR}"
```

## Why Use ARGO_ Prefix?

The `ARGO_` prefix serves important purposes:

1. **Security**: Only exposes necessary configuration to ArgoCD, not credentials
2. **Clarity**: Makes it obvious which variables are for templating vs runtime
3. **Flexibility**: Allows same variable names for different contexts (e.g., `QNAP_VAULT_ADDR` for scripts, `ARGO_NAS_VAULT_ADDR` for manifests)
4. **Best Practice**: Secrets should come from Vault via ESO, not ConfigMaps
