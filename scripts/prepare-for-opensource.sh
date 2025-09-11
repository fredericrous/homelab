#!/bin/bash
# Prepare manifests for open source by replacing sensitive values

set -euo pipefail

# Default placeholders
DOMAIN_PLACEHOLDER="yourdomain.com"
VAULT_ADDR_PLACEHOLDER="http://your-nas-ip:8200"
NFS_SERVER_PLACEHOLDER="your-nas-ip"

# Replace all instances
find manifests -name "*.yaml" -type f | while read -r file; do
    # Skip example files
    if [[ $file == *.example.yaml ]]; then
        continue
    fi
    
    # Replace sensitive values with placeholders
    sed -i.bak \
        -e "s/daddyshome\.fr/${DOMAIN_PLACEHOLDER}/g" \
        -e "s/192\.168\.1\.42/${NFS_SERVER_PLACEHOLDER}/g" \
        -e "s|http://192.168.1.42:61200|${VAULT_ADDR_PLACEHOLDER}|g" \
        "$file"
        
    # Remove backup files
    rm -f "${file}.bak"
done

echo "✅ Replaced sensitive values with placeholders"
echo ""
echo "To deploy, users should:"
echo "1. Fork this repository"
echo "2. Run: find manifests -name '*.yaml' -exec sed -i 's/${DOMAIN_PLACEHOLDER}/theirdomain.com/g' {} \;"
echo "3. Run: find manifests -name '*.yaml' -exec sed -i 's/${VAULT_ADDR_PLACEHOLDER}/http://their-nas:8200/g' {} \;"