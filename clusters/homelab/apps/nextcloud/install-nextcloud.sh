#!/bin/sh
set -e

# Get environment variables
POD=$(kubectl get pods -n nextcloud -l app.kubernetes.io/name=nextcloud -o jsonpath='{.items[0].metadata.name}')
echo "Found pod: $POD"

# Get passwords from secrets
ADMIN_USER=$(kubectl get secret -n nextcloud nextcloud-admin -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PASSWORD=$(kubectl get secret -n nextcloud nextcloud-admin -o jsonpath='{.data.password}' | base64 -d)
DB_PASSWORD=$(kubectl get secret -n nextcloud nextcloud-db -o jsonpath='{.data.password}' | base64 -d)

echo "Installing Nextcloud..."

# Run the installation
kubectl exec -n nextcloud $POD -c nextcloud -- php occ maintenance:install \
  --database=pgsql \
  --database-host=postgres-apps-rw.postgres.svc.cluster.local \
  --database-name=nextcloud \
  --database-user=nextcloud \
  --database-pass="$DB_PASSWORD" \
  --admin-user="$ADMIN_USER" \
  --admin-pass="$ADMIN_PASSWORD" \
  --data-dir=/var/www/html/data

# Configure trusted domains
echo "Configuring trusted domains..."
kubectl exec -n nextcloud $POD -c nextcloud -- php occ config:system:set trusted_domains 1 --value=nextcloud.daddyshome.fr
kubectl exec -n nextcloud $POD -c nextcloud -- php occ config:system:set trusted_domains 2 --value=drive.daddyshome.fr
kubectl exec -n nextcloud $POD -c nextcloud -- php occ config:system:set trusted_domains 3 --value=drive-mobile.daddyshome.fr

echo "Nextcloud installation completed!"