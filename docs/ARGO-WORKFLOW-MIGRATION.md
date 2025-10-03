# Argo Workflow Migration Plan

This document tracks the migration of Kubernetes Jobs to Argo Workflows.

## Migration Status

### Completed
- ✅ Stremio build job → `workflow-build-stremio.yaml`
- ✅ Stremio web-copy job → `workflow-copy-stremio-web.yaml`
- ✅ Harbor database init job → `workflow-harbor-db-init.yaml`
- ✅ Harbor vault populate job → `workflow-harbor-vault-populate.yaml`
- ✅ Vault populate workflow template → `workflow-template-vault-populate.yaml`

### High Priority - Database Initialization Jobs
These jobs would benefit from workflow features like conditional execution and better error handling:
- [ ] `apps/authelia/authelia-db-init-job.yaml`
- [ ] `apps/authelia/postgres-setup.yaml`
- [x] `apps/harbor/harbor-db-init-job.yaml` → `workflow-harbor-db-init.yaml`
- [ ] `apps/lldap/database/postgres-setup.yaml`
- [ ] `core/cloudnative-pg/init-databases-job.yaml`
- [ ] `core/argo-workflows/argo-db-init-job.yaml`

### High Priority - Vault Populate Jobs
These jobs share similar patterns and would benefit from a reusable workflow template:
- [ ] `apps/authelia/vault-secrets-init.yaml`
- [x] `apps/harbor/harbor-vault-populate-job.yaml` → `workflow-harbor-vault-populate.yaml`
- [ ] `apps/lldap/job-vault-populate-lldap.yaml`
- [ ] `apps/plex/job-vault-populate-plex.yaml`
- [ ] `core/argo-workflows/argo-vault-populate-job.yaml`
- [ ] `core/cloudnative-pg/job-populate-vault-secrets.yaml`
- [ ] `core/vault/job-vault-populate-secrets.yaml`

### Medium Priority - Vault Configuration Jobs
These jobs configure Vault access for different services:
- [ ] `core/external-secrets-operator/job-vault-configure-eso.yaml`
- [ ] `core/haproxy-ingress/vault-configure-haproxy.yaml`
- [ ] `core/vault/job-configure-app-ovh-access.yaml`
- [ ] `core/vault/job-configure-cert-manager-vault-access.yaml`
- [ ] `core/vault/job-vault-configure-kv.yaml`
- [ ] `core/vault/vault-configure-argocd-job.yaml`

### Low Priority - Application Configuration Jobs
These are one-time setup jobs that might not benefit as much from workflow features:
- [ ] `apps/nextcloud/job-configure-local-external-storage.yaml`
- [ ] `apps/nextcloud/job-configure-utf8-support.yaml`
- [ ] `apps/nextcloud/job-initial-setup.yaml`
- [ ] `apps/nextcloud/job-postsync-configure.yaml`
- [ ] `apps/nextcloud/job-presync-database.yaml`
- [ ] `core/minio/job-configure-lifecycle.yaml`

### Workflow Templates
To avoid duplication, we have created and need to create reusable workflow templates:

#### Created Templates
- [x] **Vault populate template** (`workflow-template-vault-populate.yaml`)
  - wait-vault-ready: Wait for Vault to be unsealed
  - check-vault-secret: Check if a secret exists
  - create-vault-secret: Create a new secret
  - generate-password: Generate random passwords
  - generate-htpasswd: Create htpasswd entries

#### Templates Still Needed
- [ ] **Database initialization** - Create database, user, and grants
- [ ] **Vault configure** - Set up policies and roles for service authentication

### Jobs to Keep as Kubernetes Jobs
Some jobs are better kept as regular Jobs:
- ArgoCD bootstrap job (runs before Argo Workflows is available)
- Helm chart hook jobs (managed by Helm lifecycle)
- CronJob-triggered jobs (already have scheduling)

## Benefits of Migration

1. **Better visibility**: Argo UI shows step-by-step progress
2. **Retry capabilities**: Individual steps can be retried
3. **Conditional execution**: Skip steps if preconditions are met
4. **Parallel execution**: Run independent tasks concurrently
5. **Artifacts**: Pass data between steps more easily
6. **Templates**: Reuse common patterns across workflows

## Migration Strategy

1. Create reusable workflow templates for common patterns
2. Migrate high-priority jobs first (database init and vault populate)
3. Test each workflow thoroughly before removing the original job
4. Update kustomization files to use workflows instead of jobs
5. Document any behavioral changes for operators