#!/bin/bash
# setup-transit-token.sh - Set up vault transit token for terraform deployment

set -euo pipefail

# Check if token files already exist from Taskfile
if [ -f /tmp/vault-transit-token ] && [ -s /tmp/vault-transit-token ]; then
    echo "✅ Transit token already exists from Taskfile"
    exit 0
fi

# Check environment variable from Taskfile export
if [ -f /tmp/vault-transit-env ]; then
    source /tmp/vault-transit-env
fi

# Transit token should be provided via environment variable or prompt
if [ -z "${K8S_VAULT_TRANSIT_TOKEN:-}" ]; then
    echo "Transit token not found in environment."
    echo "Please provide the Vault transit token:"
    echo "(Found in CLAUDE.local.md under 'Transit Token for K8s Vault')"
    read -s TRANSIT_TOKEN
    echo
else
    TRANSIT_TOKEN="$K8S_VAULT_TRANSIT_TOKEN"
    echo "✅ Using transit token from environment"
fi

if [ -z "$TRANSIT_TOKEN" ]; then
    echo "❌ Error: Transit token cannot be empty"
    exit 1
fi

# Create token file for vault-sync-enhanced.sh
echo "$TRANSIT_TOKEN" > /tmp/vault-transit-token
chmod 600 /tmp/vault-transit-token

echo "✅ Transit token saved to /tmp/vault-transit-token"

# Also create environment file as backup
cat > /tmp/vault-transit-env <<EOF
K8S_VAULT_TRANSIT_TOKEN="$TRANSIT_TOKEN"
EOF
chmod 600 /tmp/vault-transit-env

echo "✅ Transit token environment saved to /tmp/vault-transit-env"