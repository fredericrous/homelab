#!/bin/bash
set -e

# Retention: 60 days on QNAP MinIO (covers 8+ weeks for S3 weekly sync)
RETENTION_DAYS=60

echo "$(date): Starting QNAP MinIO cleanup (retention: $RETENTION_DAYS days)..."

# Configure MinIO client
mc alias set local http://localhost:9000 admin ${MINIO_ROOT_PASSWORD:-changeme123}

# Find and remove backups older than retention period
echo "Looking for backups older than $RETENTION_DAYS days..."

# Get all backup folders with timestamps
OLD_BACKUPS=$(mc find local/velero-backups/backups/ --older-than "${RETENTION_DAYS}d" --name "*" -type d | grep -E "[0-9]{14}$" || true)

if [ -n "$OLD_BACKUPS" ]; then
    BACKUP_COUNT=$(echo "$OLD_BACKUPS" | wc -l)
    echo "Found $BACKUP_COUNT old backups to remove"
    
    while IFS= read -r backup; do
        if [ -n "$backup" ]; then
            echo "Removing old backup: $backup"
            mc rm -r --force "$backup"
        fi
    done <<< "$OLD_BACKUPS"
    
    echo "Cleanup complete. Removed $BACKUP_COUNT old backups."
else
    echo "No backups older than $RETENTION_DAYS days found."
fi

# Show current storage usage
echo ""
echo "Current storage usage:"
mc du -h local/velero-backups

echo "$(date): QNAP MinIO cleanup completed!"