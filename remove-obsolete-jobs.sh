#!/bin/bash
# Script to remove obsolete Kubernetes Job files that have been replaced by Argo Workflows

cd /Users/fredericrous/Developer/Perso/homelab

# List of files to remove
FILES_TO_REMOVE=(
  # Authelia
  "manifests/apps/authelia/postgres-setup.yaml"
  "manifests/apps/authelia/vault-secrets-init.yaml"
  "manifests/apps/authelia/authelia-db-init-job.yaml"
  "manifests/apps/authelia/authelia-db-cleanup-job.yaml"
  "manifests/apps/authelia/authelia-db-reset-job.yaml"
  
  # LLDAP
  "manifests/apps/lldap/job-vault-populate-lldap.yaml"
  "manifests/apps/lldap/job-reset-admin-password.yaml"
  "manifests/apps/lldap/database/postgres-setup.yaml"
  
  # Nextcloud
  "manifests/apps/nextcloud/job-presync-vault-setup.yaml"
  "manifests/apps/nextcloud/job-presync-database.yaml"
  "manifests/apps/nextcloud/job-initial-setup.yaml"
  "manifests/apps/nextcloud/job-postsync-fix-permissions.yaml"
  "manifests/apps/nextcloud/job-configure-local-external-storage.yaml"
  "manifests/apps/nextcloud/job-configure-utf8-support.yaml"
  "manifests/apps/nextcloud/job-postsync-configure.yaml"
  
  # Plex
  "manifests/apps/plex/job-vault-populate-plex.yaml"
  
  # Stremio
  "manifests/apps/stremio/build-job.yaml"
  "manifests/apps/stremio/stremio-web-copy-job.yaml"
  "manifests/apps/stremio/stremio-web-pull-job.yaml"
  
  # Vault
  "manifests/core/vault/job-vault-configure-kv.yaml"
  "manifests/core/vault/vault-configure-argocd-job.yaml"
  "manifests/core/vault/job-configure-app-ovh-access.yaml"
  "manifests/core/vault/job-configure-cert-manager-vault-access.yaml"
  "manifests/core/vault/job-vault-populate-secrets.yaml"
  "manifests/core/vault/job-vault-validate.yaml"
  
  # CloudNativePG
  "manifests/core/cloudnative-pg/job-populate-vault-secrets.yaml"
  "manifests/core/cloudnative-pg/job-post-sync-configure.yaml"
  "manifests/core/cloudnative-pg/job-presync-vault-setup.yaml"
  "manifests/core/cloudnative-pg/init-databases-job.yaml"
  "manifests/core/cloudnative-pg/harbor-database.yaml"
  "manifests/core/cloudnative-pg/create-app-db.yaml"
  
  # MinIO
  "manifests/core/minio/job-configure-lifecycle.yaml"
  
  # Rook-Ceph
  "manifests/core/rook-ceph/fix-pool-size.yaml"
  
  # HAProxy
  "manifests/core/haproxy-ingress/vault-configure-haproxy.yaml"
  
  # External Secrets Operator
  "manifests/core/external-secrets-operator/job-vault-configure-eso.yaml"
)

echo "The following files will be removed:"
echo "================================="
for file in "${FILES_TO_REMOVE[@]}"; do
  if [ -f "$file" ]; then
    echo "✓ $file"
  else
    echo "✗ $file (not found)"
  fi
done

echo ""
read -p "Do you want to proceed with deletion? (y/N) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
  for file in "${FILES_TO_REMOVE[@]}"; do
    if [ -f "$file" ]; then
      rm -f "$file"
      echo "Removed: $file"
    fi
  done
  echo "Cleanup completed!"
else
  echo "Cleanup cancelled."
fi