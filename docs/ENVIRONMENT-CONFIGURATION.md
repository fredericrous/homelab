# Environment Configuration

This homelab repository is designed to be fully open-source while keeping environment-specific values (IPs, domains, etc.) separate.

## Architecture

1. **Public Repository** (`fredericrous/homelab`): Contains all manifests with placeholders like `${QNAP_VAULT_ADDR}`
2. **Private Repository** (`fredericrous/homelab-values`): Contains your `.env` file with actual values
3. **ConfigMap Bootstrap**: Creates a ConfigMap in ArgoCD namespace from your `.env` file
4. **ArgoCD Plugin**: The envsubst plugin reads from the ConfigMap and substitutes placeholders

## Initial Setup

### 1. Fork/Clone Repositories

```bash
# Clone the public homelab repository
git clone https://github.com/fredericrous/homelab
cd homelab

# Create your private homelab-values repository on GitHub
# Make sure it's PRIVATE!
```

### 2. Configure Your Private Repository

1. Create a **private** repository named `homelab-values` on GitHub
2. Configure the repository URL in your `.env` file:

```bash
# For SSH (recommended - uses your existing GitHub SSH access)
HOMELAB_VALUES_REPO=git@github.com:YOUR-USERNAME/homelab-values.git

# For HTTPS (include token in URL)
HOMELAB_VALUES_REPO=https://YOUR-TOKEN@github.com/YOUR-USERNAME/homelab-values.git
```

No special SSH configuration needed - the `sync-env` task will use your existing Git credentials.

### 3. Configure Your Environment

```bash
# Copy the example environment file
cp .env.example .env

# Edit with your values
vim .env

# Sync to your private repository (automatic)
task sync-env
```

### 4. Deploy

The deployment process automatically handles the environment configuration:

```bash
# This will:
# 1. Run sync-env to update homelab-values repository
# 2. Deploy the cluster
# 3. Create the values ConfigMap during ArgoCD installation
task deploy
```

## How It Works

### During Deployment

1. `task deploy` runs `task sync-env` which copies `.env` to your private `homelab-values` repository
2. Stage 5 of deployment creates a ConfigMap from `.env`:
   ```bash
   kubectl create configmap argocd-envsubst-values --from-env-file=.env -n argocd
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

# Sync to private repository
task sync-env

# Update the ConfigMap in cluster
task update-values

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

4. Sync and update:
   ```bash
   task sync-env
   task update-values
   ```

## Security Considerations

- **Never commit `.env` to the public repository** (it's in `.gitignore`)
- Keep `homelab-values` repository **private**
- The ConfigMap is created in `argocd` namespace with cluster access
- For truly sensitive data (passwords, API keys), use Vault instead
- The plugin only substitutes variables, it doesn't execute code

### Git Access Security

The `sync-env` task needs push access to your private repository:

1. **SSH Keys** (Recommended):
   - Use deploy keys with write access
   - Limit key to single repository
   - Rotate keys periodically

2. **Personal Access Tokens**:
   - Create fine-grained tokens
   - Limit scope to single repository
   - Set expiration dates
   - Never commit tokens

3. **Repository Settings**:
   - Enable branch protection on main
   - Require PR reviews (if team environment)
   - Enable audit logging
   - Regular access reviews

### Temporary Files

The `sync-env` task uses `.task/` directory for temporary clones:
- Automatically cleaned up after each run
- Already in `.gitignore`
- Never leaves sensitive data on disk

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
