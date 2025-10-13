#!/bin/sh
# Auto-unseal script for NAS Vault using GPG-encrypted keys
# Runs inside Kubernetes Job to unseal Vault after restart

set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://vault-nas-vault.vault.svc.cluster.local:8200}"
UNSEAL_FILE="/unseal/unseal-keys.txt.gpg"
MAX_RETRIES=30
RETRY_INTERVAL=5

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [AUTO-UNSEAL] $1"
}

error() {
    log "ERROR: $1"
    exit 1
}

wait_for_vault() {
    log "Waiting for Vault to be reachable at $VAULT_ADDR..."
    
    local retries=0
    while [ $retries -lt $MAX_RETRIES ]; do
        if vault status >/dev/null 2>&1; then
            log "Vault is reachable"
            return 0
        elif vault status 2>&1 | grep -q "connection refused"; then
            log "Vault not yet reachable (attempt $((retries + 1))/$MAX_RETRIES)"
        elif vault status 2>&1 | grep -q "sealed"; then
            log "Vault is reachable but sealed - proceeding with unseal"
            return 0
        else
            log "Vault check returned unexpected status (attempt $((retries + 1))/$MAX_RETRIES)"
        fi
        
        retries=$((retries + 1))
        sleep $RETRY_INTERVAL
    done
    
    error "Vault did not become reachable after $((MAX_RETRIES * RETRY_INTERVAL)) seconds"
}

check_vault_status() {
    log "Checking Vault seal status..."
    
    if ! vault status >/dev/null 2>&1; then
        log "Cannot connect to Vault - skipping unseal"
        exit 0
    fi
    
    # Check if Vault is already unsealed
    if vault status | grep -q "Sealed.*false"; then
        log "✅ Vault is already unsealed - nothing to do"
        exit 0
    fi
    
    if vault status | grep -q "Sealed.*true"; then
        log "🔒 Vault is sealed - proceeding with unseal"
        return 0
    fi
    
    log "Cannot determine Vault seal status - skipping unseal"
    exit 0
}

decrypt_and_unseal() {
    log "Decrypting unseal keys..."
    
    if [ ! -f "$UNSEAL_FILE" ]; then
        log "Unseal file not found at $UNSEAL_FILE - keys may not be ready yet"
        exit 0
    fi
    
    # Import GPG private key (required for decryption)
    if [ -f "/unseal/gpg-private-key.asc" ]; then
        log "Importing GPG private key..."
        gpg --batch --quiet --import /unseal/gpg-private-key.asc 2>/dev/null || {
            log "GPG key import failed or key already imported"
        }
    else
        log "GPG private key not found at /unseal/gpg-private-key.asc - cannot decrypt"
        exit 0
    fi
    
    # Decrypt the unseal key
    log "Decrypting unseal key..."
    UNSEAL_KEY=$(gpg --quiet --batch --decrypt "$UNSEAL_FILE" 2>/dev/null)
    
    if [ -z "$UNSEAL_KEY" ]; then
        log "Failed to decrypt unseal key - may need GPG passphrase or key not ready"
        exit 0
    fi
    
    log "Successfully decrypted unseal key"
    
    # Unseal Vault
    log "Unsealing Vault..."
    if vault operator unseal "$UNSEAL_KEY" >/dev/null; then
        log "✅ Vault unsealed successfully"
    else
        log "Failed to unseal Vault"
        exit 0
    fi
}

verify_unseal() {
    log "Verifying Vault is unsealed..."
    
    if vault status | grep -q "Sealed.*false"; then
        log "✅ Vault is unsealed and ready"
        return 0
    else
        error "Vault is still sealed after unseal operation"
    fi
}

main() {
    log "🔐 Starting Vault auto-unseal process"
    
    export VAULT_ADDR="$VAULT_ADDR"
    
    wait_for_vault
    
    if check_vault_status; then
        decrypt_and_unseal
        verify_unseal
        log "🎉 Auto-unseal completed successfully"
    else
        log "🎉 Vault already unsealed - job completed"
    fi
}

main "$@"