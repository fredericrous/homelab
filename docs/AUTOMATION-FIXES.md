# GitOps Automation Fixes

This document summarizes the automation improvements made to ensure CloudNative-PG and Nextcloud work seamlessly with `task deploy`.

## CloudNative-PG Automation

### PreSync Hook (`job-presync-vault-setup.yaml`)
- Gracefully handles missing Vault admin token (fresh cluster scenario)
- Exits with code 0 if Vault not ready (allows ArgoCD to continue)
- Creates postgres superuser credentials in Vault if missing
- Secret mount marked as `optional: true`

### PostSync Hook (`job-post-sync-configure.yaml`)
- Creates postgres namespace if missing
- Creates ExternalSecret for postgres superuser
- Waits for operator to be ready

## Nextcloud Automation

### PreSync Hooks

1. **Wave 0: Vault Setup** (`job-presync-vault-setup.yaml`)
   - Populates Nextcloud secrets in Vault if missing
   - Handles missing Vault token gracefully

2. **Wave 1: Database Setup** (`job-presync-database.yaml`)
   - Creates database and user
   - Updates password if user exists
   - Sets proper UTF-8 encoding

### Sync Hook

**Wave 10: Initial Setup** (`job-initial-setup.yaml`)
- Fixed secret name from `nextcloud-secret` to `nextcloud-secrets`
- Fixed PostgreSQL service name to `postgres-apps-rw`
- Added proper variable expansion with bash
- Fixed permissions before installation
- Added jq installation for status checking
- Updated to nextcloud:29-apache image

### PostSync Hooks

1. **Wave 5: Fix Permissions** (`job-postsync-fix-permissions.yaml`)
   - Fixes data directory permissions (chmod 0770)
   - Fixes ownership to www-data
   - Runs early to prevent permission errors

2. **Wave 20: UTF-8 Configuration** (`job-configure-utf8-support.yaml`)
   - Removed volume mount (uses kubectl exec instead)
   - Prevents PVC conflicts

3. **Wave 30: External Storage** (`job-configure-local-external-storage.yaml`)
   - Keeps volume mounts (needed for SMB/NFS)
   - Runs after main configuration

4. **PostSync: Final Configuration** (`job-postsync-configure.yaml`)
   - Uses kubectl to configure via exec
   - No volume mounts needed

## Key Design Principles

1. **Graceful Degradation**
   - Jobs exit with code 0 when dependencies aren't ready
   - Allows ArgoCD sync to complete and retry later

2. **Idempotency**
   - All operations check existing state
   - Safe to run multiple times

3. **Proper Sequencing**
   - ArgoCD sync waves ensure correct order
   - Init containers wait for dependencies

4. **No PVC Conflicts**
   - Only jobs that need the PVC mount it
   - PostSync jobs use kubectl exec instead

## Testing

Run validation script after deployment:
```bash
./terraform/scripts/validate-nextcloud-deployment.sh
```

## Result

With these fixes, running `task destroy` followed by `task deploy` will:
1. Deploy all infrastructure in correct order
2. Initialize Vault automatically
3. Configure External Secrets Operator
4. Deploy CloudNative-PG and create PostgreSQL cluster
5. Deploy and configure Nextcloud completely
6. No manual intervention required!