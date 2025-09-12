#!/bin/sh
set -e

# MinIO configuration
MINIO_ALIAS="local"
MINIO_URL="http://minio:9000"
MINIO_USER="admin"
MINIO_PASS="${MINIO_ROOT_PASSWORD}"

echo "🔧 Configuring MinIO client..."
mc alias set $MINIO_ALIAS $MINIO_URL $MINIO_USER $MINIO_PASS

echo "📦 Creating backup bucket if needed..."
mc mb $MINIO_ALIAS/velero-backups --ignore-existing

echo "🗓️ Setting up lifecycle policy for QNAP MinIO (60 days retention)..."
cat > /tmp/lifecycle.json <<'EOF'
{
    "Rules": [
        {
            "ID": "DeleteOldBackups",
            "Status": "Enabled",
            "Expiration": {
                "Days": 60
            },
            "Filter": {
                "Prefix": "backups/"
            }
        }
    ]
}
EOF

mc ilm import $MINIO_ALIAS/velero-backups < /tmp/lifecycle.json

echo "✅ Lifecycle policy configured! Old backups will be automatically deleted after 60 days."

# Show the policy
echo ""
echo "Current lifecycle policy:"
mc ilm ls $MINIO_ALIAS/velero-backups