# Environment Configuration

This project uses environment variables to make it portable across different environments.

## Quick Start

1. Copy the example environment file:
   ```bash
   cp .env.example .env
   ```

2. Edit `.env` with your values:
   ```bash
   # QNAP/NAS Configuration
   QNAP_VAULT_ADDR=http://192.168.1.42:61200  # Your QNAP Vault address
   QNAP_VAULT_TOKEN=hvs.XXXX                   # Your QNAP Vault token

   # OVH DNS Configuration (for Let's Encrypt)
   OVH_APPLICATION_KEY=your-key
   OVH_APPLICATION_SECRET=your-secret
   OVH_CONSUMER_KEY=your-consumer-key

   # Cluster Configuration
   CLUSTER_DOMAIN=yourdomain.com
   ```

3. Deploy:
   ```bash
   task deploy
   ```

## Environment Variables

### Required Variables

| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `QNAP_VAULT_ADDR` | QNAP Vault URL | `http://192.168.1.42:61200` | `http://nas.local:61200` |
| `QNAP_VAULT_TOKEN` | QNAP Vault authentication token | None | `hvs.XXXX` |
| `OVH_APPLICATION_KEY` | OVH API application key | None | `a4598a81b100e759` |
| `OVH_APPLICATION_SECRET` | OVH API application secret | None | `2066396e3b624e34d4f1a3d009ca0139` |
| `OVH_CONSUMER_KEY` | OVH API consumer key | None | `cb8d03d3d3a2de55f9df196190022425` |

### Optional Variables

| Variable | Description | Default | Example |
|----------|-------------|---------|---------|
| `CLUSTER_DOMAIN` | Base domain for cluster services | `daddyshome.fr` | `homelab.local` |
| `K8S_VAULT_TRANSIT_TOKEN` | Override transit token (normally auto-retrieved) | None | `hvs.YYYY` |

## How It Works

1. **Task Integration**: The `Taskfile.yml` loads `.env` automatically via `dotenv: ['.env']`

2. **Script Usage**: All scripts use `${QNAP_VAULT_ADDR:-default}` pattern for flexibility

3. **Kubernetes Manifests**: The QNAP address is stored in a static ConfigMap (`manifests/core/vault/qnap-vault-config.yaml`). To change it, edit the ConfigMap directly and commit the change.

4. **Terraform**: Terraform scripts inherit environment variables from the Task runner

## Sharing the Project

When sharing this project:

1. **Never commit `.env`** - it's in `.gitignore`
2. **Update `.env.example`** with any new variables
3. **Use defaults** where sensible (e.g., standard ports)
4. **Document** any environment-specific requirements

## Troubleshooting

### QNAP Vault Connection Issues
```bash
# Test connectivity
curl -s $QNAP_VAULT_ADDR/v1/sys/health

# Check authentication
export VAULT_ADDR=$QNAP_VAULT_ADDR
vault token lookup
```

### Missing Environment Variables
The deployment will check for required variables and provide clear error messages:
```
❌ Transit token not found
To deploy, you need to:
1. Deploy QNAP services first: task nas:deploy
2. Set up transit token: task nas:vault-transit
3. Export QNAP_VAULT_TOKEN=<token>
```

## Best Practices

1. **Use `.env` for local development** - Keep environment-specific values out of code
2. **Use descriptive defaults** - Make the project work with minimal configuration
3. **Validate early** - Check environment in pre-flight scripts
4. **Provide clear errors** - Help users understand what's missing
5. **Document everything** - Explain why each variable is needed