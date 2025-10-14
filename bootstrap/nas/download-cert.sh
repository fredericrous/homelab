#!/bin/bash
USERNAME="${1:-$USER}"
if [ -z "$VAULT_ADDR" ]; then
    echo "Set VAULT_ADDR first"
    exit 1
fi
if ! vault token lookup &>/dev/null 2>&1; then
    echo "Not authenticated to Vault. Run: vault login"
    exit 1
fi
echo "📥 Downloading certificate for $USERNAME..."
vault kv get -field=p12 secret/pki/clients/$USERNAME | base64 -d > "$USERNAME.p12"
echo "✅ Certificate saved to $USERNAME.p12"
echo "   Import this file into your browser/system"
echo "   Password: (leave empty/blank)"
