#!/bin/bash
# Bootstrap script to initialize Vault with single key and encrypt with GPG

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNSEAL_DIR="$SCRIPT_DIR/../unseal"
NAS_HOST="${NAS_HOST:-admin@192.168.1.42}"
NFS_VAULT_DIR="/VMs/kubernetes/vault"
GPG_RECIPIENT="${GPG_RECIPIENT:-admin@daddyshome.fr}"
VAULT_ADDR="${VAULT_ADDR:-http://192.168.1.42:61200}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARNING:${NC} $1"
}

error() {
    echo -e "${RED}[$(date +'%H:%M:%S')] ERROR:${NC} $1"
    exit 1
}

success() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')] SUCCESS:${NC} $1"
}

check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if vault is accessible
    if ! command -v vault &> /dev/null; then
        error "vault command not found. Please install Vault CLI"
    fi
    
    # Check if gpg is available
    if ! command -v gpg &> /dev/null; then
        error "gpg command not found. Please install GnuPG"
    fi
    
    # Check Vault connectivity
    export VAULT_ADDR="$VAULT_ADDR"
    if ! vault status &>/dev/null; then
        if vault status 2>&1 | grep -q "connection refused"; then
            error "Cannot connect to Vault at $VAULT_ADDR. Is Vault running?"
        elif vault status 2>&1 | grep -q "not been initialized"; then
            log "Vault is not initialized - this is expected for bootstrap"
        else
            warn "Vault status check failed, but continuing with initialization"
        fi
    else
        if vault status | grep -q "Initialized.*true"; then
            error "Vault is already initialized. This script is for first-time setup only."
        fi
    fi
    
    # Check/create unseal directory
    mkdir -p "$UNSEAL_DIR"
    
    success "Prerequisites check passed"
}

generate_gpg_key_if_needed() {
    log "Checking for GPG key for $GPG_RECIPIENT..."
    
    if gpg --list-secret-keys "$GPG_RECIPIENT" &>/dev/null; then
        success "GPG key for $GPG_RECIPIENT already exists"
        return
    fi
    
    warn "No GPG key found for $GPG_RECIPIENT. Generating new key..."
    
    # Generate GPG key batch configuration
    cat > /tmp/gpg-batch <<EOF
%echo Generating homelab vault key
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: Homelab Vault Admin
Name-Email: $GPG_RECIPIENT
Expire-Date: 2y
Passphrase: 
%commit
%echo GPG key generation complete
EOF

    log "Generating GPG key (this may take a while)..."
    gpg --batch --generate-key /tmp/gpg-batch
    rm -f /tmp/gpg-batch
    
    success "GPG key generated for $GPG_RECIPIENT"
}

initialize_vault() {
    log "Initializing Vault with single key (no threshold)..."
    
    # Initialize with 1 key share and threshold of 1
    INIT_OUTPUT=$(vault operator init -key-shares=1 -key-threshold=1 -format=json)
    
    # Extract unseal key and root token
    UNSEAL_KEY=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
    ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')
    
    if [[ -z "$UNSEAL_KEY" || -z "$ROOT_TOKEN" ]]; then
        error "Failed to extract unseal key or root token from initialization"
    fi
    
    success "Vault initialized successfully"
    
    # Store keys in temporary files
    echo "$UNSEAL_KEY" > /tmp/vault-unseal-key
    echo "$ROOT_TOKEN" > /tmp/vault-root-token
    
    log "Unseal key: $UNSEAL_KEY"
    log "Root token: $ROOT_TOKEN"
}

encrypt_keys() {
    log "Encrypting unseal key with GPG..."
    
    # Ensure local unseal directory exists
    mkdir -p "$UNSEAL_DIR"
    
    # Encrypt the unseal key
    gpg --trust-model always \
        --cipher-algo AES256 \
        --compress-algo 1 \
        --compress-level 6 \
        --recipient "$GPG_RECIPIENT" \
        --encrypt \
        --armor \
        --output "$UNSEAL_DIR/unseal-keys.txt.gpg" \
        /tmp/vault-unseal-key
    
    # Encrypt the root token separately for manual access
    gpg --trust-model always \
        --cipher-algo AES256 \
        --compress-algo 1 \
        --compress-level 6 \
        --recipient "$GPG_RECIPIENT" \
        --encrypt \
        --armor \
        --output "$UNSEAL_DIR/root-token.txt.gpg" \
        /tmp/vault-root-token
    
    # Export GPG private key for auto-unseal job
    log "Exporting GPG private key for auto-unseal..."
    gpg --export-secret-keys --armor "$GPG_RECIPIENT" > "$UNSEAL_DIR/gpg-private-key.asc"
    
    # Keys are stored locally and will be copied to NFS via Kubernetes Job
    log "Keys stored locally at $UNSEAL_DIR/"
    log "Use 'task nas:copy-keys-to-nfs' to copy keys to NAS via Kubernetes Job"
    
    # Clean up temporary files
    shred -u /tmp/vault-unseal-key /tmp/vault-root-token
    
    success "Keys encrypted and stored in $UNSEAL_DIR/"
}

unseal_vault() {
    log "Unsealing Vault for initial setup..."
    
    # Decrypt and use the unseal key
    UNSEAL_KEY=$(gpg --quiet --batch --decrypt "$UNSEAL_DIR/unseal-keys.txt.gpg" 2>/dev/null)
    vault operator unseal "$UNSEAL_KEY"
    
    success "Vault unsealed successfully"
}

setup_initial_config() {
    log "Setting up initial Vault configuration..."
    
    # Login with root token
    ROOT_TOKEN=$(gpg --quiet --batch --decrypt "$UNSEAL_DIR/root-token.txt.gpg" 2>/dev/null)
    vault auth "$ROOT_TOKEN"
    
    # Enable KV v2 secrets engine
    if ! vault secrets list | grep -q "^secret/"; then
        log "Enabling KV v2 secrets engine..."
        vault secrets enable -path=secret kv-v2
    else
        log "KV v2 secrets engine already enabled"
    fi
    
    success "Initial Vault configuration complete"
}

show_next_steps() {
    echo ""
    success "🎉 Vault bootstrap complete!"
    echo ""
    echo "📋 What was created:"
    echo "   - Vault initialized with single unseal key"
    echo "   - Unseal key encrypted with GPG at: $UNSEAL_DIR/unseal-keys.txt.gpg"
    echo "   - Root token encrypted with GPG at: $UNSEAL_DIR/root-token.txt.gpg"
    echo "   - KV v2 secrets engine enabled"
    echo ""
    echo "🔑 To decrypt and view your root token:"
    echo "   gpg --decrypt $UNSEAL_DIR/root-token.txt.gpg"
    echo ""
    echo "📝 Add the root token to your .env file:"
    echo "   QNAP_VAULT_TOKEN=\$(gpg --quiet --batch --decrypt $UNSEAL_DIR/root-token.txt.gpg)"
    echo ""
    echo "🚀 Next steps:"
    echo "   task nas:copy-keys-to-nfs       # Copy keys to NFS via Kubernetes Job"
    echo "   task nas:vault-secrets          # Setup MinIO and AWS secrets"
    echo "   task nas:vault-transit          # Setup transit unsealing for main cluster"
    echo "   task nas:vault-auto-unseal      # Deploy auto-unseal job"
    echo ""
    echo "⚠️  IMPORTANT: Back up your GPG private key!"
    echo "   gpg --export-secret-keys $GPG_RECIPIENT > ~/homelab-vault-gpg-backup.key"
}

main() {
    echo ""
    log "🔐 Starting Vault Bootstrap with GPG encryption"
    echo ""
    
    check_prerequisites
    generate_gpg_key_if_needed
    initialize_vault
    encrypt_keys
    unseal_vault
    setup_initial_config
    show_next_steps
}

# Allow setting GPG recipient via argument
if [[ $# -gt 0 ]]; then
    GPG_RECIPIENT="$1"
fi

main "$@"