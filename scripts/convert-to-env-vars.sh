#!/bin/bash
# Convert manifests to use environment variables

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🔄 Converting manifests to use environment variables..."

# Domain replacements
find "$ROOT_DIR/manifests" -name "*.yaml" -type f | while read -r file; do
    # Skip example files and scripts
    if [[ $file == *.example.yaml ]] || [[ $file == *scripts/* ]]; then
        continue
    fi
    
    # Replace domain references
    sed -i.bak \
        -e 's/daddyshome\.fr/${CLUSTER_DOMAIN}/g' \
        -e 's/192\.168\.1\.42/${NFS_SERVER}/g' \
        -e 's|http://192.168.1.42:61200|${QNAP_VAULT_ADDR}|g' \
        -e 's|http://192.168.1.42:8200|${QNAP_VAULT_ADDR}|g' \
        "$file"
done

# Clean up backup files
find "$ROOT_DIR/manifests" -name "*.yaml.bak" -type f -delete

echo "✅ Conversion complete!"
echo ""
echo "Files updated to use environment variables:"
echo "  \${CLUSTER_DOMAIN} - Your domain"
echo "  \${QNAP_VAULT_ADDR} - QNAP Vault address"
echo "  \${NFS_SERVER} - NFS server IP"
echo ""
echo "These will be substituted by ArgoCD using the kustomize-envsubst plugin"