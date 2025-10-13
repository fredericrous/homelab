#!/bin/bash
set -euo pipefail

# Auto-unseal script for Vault using GPG-encrypted keys
echo "🔐 Vault Auto-Unseal Script Starting..."

# Configuration
VAULT_ADDR="${VAULT_ADDR:-http://vault-vault-nas.vault.svc.cluster.local:8200}"
KEYS_DIR="/unseal"
GPG_KEY_FILE="$KEYS_DIR/gpg-private-key.asc"
ENCRYPTED_UNSEAL_KEY="$KEYS_DIR/unseal-keys.txt.gpg"

echo "📋 Configuration:"
echo "  Vault Address: $VAULT_ADDR"
echo "  Keys Directory: $KEYS_DIR"
echo "  GPG Key File: $GPG_KEY_FILE"
echo "  Encrypted Unseal Key: $ENCRYPTED_UNSEAL_KEY"

# Check if Vault is accessible (accept any HTTP response, including 503 for sealed)
if ! curl -s --max-time 5 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; then
    echo "❌ Vault is not accessible at $VAULT_ADDR"
    exit 1
fi

# Check Vault initialization status
vault_status=$(curl -s "$VAULT_ADDR/v1/sys/health" 2>/dev/null || echo '{"initialized":false}')
initialized=$(echo "$vault_status" | jq -r 'if .initialized == null then "false" else (.initialized | tostring) end')
sealed=$(echo "$vault_status" | jq -r 'if .sealed == null then "true" else (.sealed | tostring) end')

echo "📊 Vault Status:"
echo "  Initialized: $initialized"
echo "  Sealed: $sealed"

if [[ "$initialized" != "true" ]]; then
    echo "❌ Vault is not initialized"
    exit 1
fi

if [[ "$sealed" != "true" ]]; then
    echo "✅ Vault is already unsealed"
    exit 0
fi

# Check if required files exist
if [[ ! -f "$GPG_KEY_FILE" ]]; then
    echo "❌ GPG private key not found at $GPG_KEY_FILE"
    echo "Run the bootstrap job to create encrypted keys first"
    exit 1
fi

if [[ ! -f "$ENCRYPTED_UNSEAL_KEY" ]]; then
    echo "❌ Encrypted unseal key not found at $ENCRYPTED_UNSEAL_KEY"
    echo "Run the bootstrap job to create encrypted keys first"
    exit 1
fi

echo "🔑 Importing GPG key..."
if ! gpg --batch --import "$GPG_KEY_FILE" >/dev/null 2>&1; then
    echo "❌ Failed to import GPG key"
    exit 1
fi

echo "🔓 Decrypting unseal key..."
if ! UNSEAL_KEY=$(gpg --quiet --batch --decrypt "$ENCRYPTED_UNSEAL_KEY" 2>/dev/null); then
    echo "❌ Failed to decrypt unseal key"
    exit 1
fi

echo "🔐 Unsealing Vault using API..."
unseal_response=$(curl -s -X PUT -d "{\"key\":\"$UNSEAL_KEY\"}" "$VAULT_ADDR/v1/sys/unseal" 2>/dev/null)

if [[ $? -ne 0 ]]; then
    echo "❌ Failed to make unseal API request"
    exit 1
fi

# Check if unsealing was successful
sealed=$(echo "$unseal_response" | jq -r 'if .sealed == null then "true" else (.sealed | tostring) end')

if [[ "$sealed" == "true" ]]; then
    echo "❌ Vault is still sealed after unseal attempt"
    echo "Response: $unseal_response"
    exit 1
fi

echo "✅ Vault unsealed successfully!"

echo "🎉 Auto-unseal completed successfully!"