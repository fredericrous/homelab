#!/bin/bash
set -euo pipefail

# Auto-unseal script for Vault using GPG-encrypted keys
echo "🔐 Vault Auto-Unseal Script Starting..."

# Configuration
VAULT_ADDR="${VAULT_ADDR:-http://vault-nas-vault.vault.svc.cluster.local:8200}"
KEYS_DIR="/unseal"
GPG_KEY_FILE="$KEYS_DIR/gpg-private-key.asc"
ENCRYPTED_UNSEAL_KEY="$KEYS_DIR/unseal-keys.txt.gpg"

echo "📋 Configuration:"
echo "  Vault Address: $VAULT_ADDR"
echo "  Keys Directory: $KEYS_DIR"
echo "  GPG Key File: $GPG_KEY_FILE"
echo "  Encrypted Unseal Key: $ENCRYPTED_UNSEAL_KEY"

# Check if Vault is accessible
if ! curl -f -s "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; then
    echo "❌ Vault is not accessible at $VAULT_ADDR"
    exit 1
fi

# Check Vault initialization status
vault_status=$(vault status -format=json 2>/dev/null || echo '{"initialized":false}')
initialized=$(echo "$vault_status" | jq -r '.initialized // false')
sealed=$(echo "$vault_status" | jq -r '.sealed // true')

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

echo "🔐 Unsealing Vault..."
if ! vault operator unseal "$UNSEAL_KEY" >/dev/null 2>&1; then
    echo "❌ Failed to unseal Vault"
    exit 1
fi

echo "✅ Vault unsealed successfully!"

# Verify Vault is unsealed
vault_status=$(vault status -format=json 2>/dev/null || echo '{"sealed":true}')
sealed=$(echo "$vault_status" | jq -r '.sealed // true')

if [[ "$sealed" == "true" ]]; then
    echo "❌ Vault is still sealed after unseal attempt"
    exit 1
fi

echo "🎉 Auto-unseal completed successfully!"