#!/bin/bash
# PKI generation script for NAS cluster
# Generates CA and client certificates, stores in Vault

set -e

# Configuration
VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
CA_VALIDITY_DAYS=3650  # 10 years
CLIENT_VALIDITY_DAYS=365  # 1 year

echo "🔐 Initializing PKI in NAS Vault..."

# Authenticate to Vault if needed
if ! vault token lookup &>/dev/null 2>&1; then
    echo "❌ Not authenticated to Vault"
    echo "   Run: vault login <token>"
    exit 1
fi

# Function to check if secret exists
secret_exists() {
    vault kv get "$1" >/dev/null 2>&1
}

# Ensure KV v2 is enabled at secret/
if ! vault secrets list | grep -q "^secret/"; then
    echo "📦 Enabling KV v2 secrets engine..."
    vault secrets enable -path=secret kv-v2
fi

# Check if CA already exists
if secret_exists "secret/pki/ca"; then
    echo "✅ CA already exists in Vault"
    CA_EXISTS=true
else
    echo "🆕 Generating new CA..."
    
    # Generate CA key
    CA_KEY_FILE=$(mktemp)
    openssl genrsa -out "$CA_KEY_FILE" 4096 2>/dev/null
    
    # Generate CA certificate
    CA_CERT_FILE=$(mktemp)
    openssl req -new -x509 -days $CA_VALIDITY_DAYS -key "$CA_KEY_FILE" -out "$CA_CERT_FILE" \
        -subj "/C=FR/ST=France/L=Home/O=DaddysHome/OU=IT/CN=DaddysHome CA" 2>/dev/null
    
    # Read files
    CA_KEY=$(cat "$CA_KEY_FILE")
    CA_CERT=$(cat "$CA_CERT_FILE")
    
    # Store in Vault
    vault kv put secret/pki/ca \
        "ca.key=$CA_KEY" \
        "ca.crt=$CA_CERT"
    
    # Cleanup temp files
    rm -f "$CA_KEY_FILE" "$CA_CERT_FILE"
    
    echo "✅ CA generated and stored in Vault"
fi

# Create policy for External Secrets Operator
echo "📝 Creating policy for ESO access..."
cat <<EOF | vault policy write eso-pki-reader -
# Read CA certificate for cross-cluster sync
path "secret/data/pki/ca" {
  capabilities = ["read"]
}

# Read specific client certificates if needed
path "secret/data/pki/clients/*" {
  capabilities = ["read"]
}

# List clients (optional)
path "secret/metadata/pki/clients" {
  capabilities = ["list"]
}
EOF

# Generate ESO token
echo "🎫 Generating token for External Secrets Operator..."
ESO_TOKEN=$(vault token create \
    -policy=eso-pki-reader \
    -display-name="eso-pki-sync" \
    -ttl=8760h \
    -renewable \
    -format=json | jq -r '.auth.client_token')

# Store for reference
vault kv put secret/tokens/eso-pki token="$ESO_TOKEN"

echo "✅ ESO token created and stored at secret/tokens/eso-pki"

# Function to generate client certificate
generate_client_cert() {
    local username=$1
    local email=$2
    
    if secret_exists "secret/pki/clients/$username"; then
        echo "⚠️  Certificate for $username already exists"
        return 0
    fi
    
    echo "🔑 Generating certificate for $username ($email)..."
    
    # Get CA from Vault
    CA_KEY=$(vault kv get -field=ca.key secret/pki/ca)
    CA_CERT=$(vault kv get -field=ca.crt secret/pki/ca)
    
    # Create temp files
    CA_KEY_FILE=$(mktemp)
    CA_CERT_FILE=$(mktemp)
    echo "$CA_KEY" > "$CA_KEY_FILE"
    echo "$CA_CERT" > "$CA_CERT_FILE"
    
    # Generate client key
    CLIENT_KEY_FILE=$(mktemp)
    openssl genrsa -out "$CLIENT_KEY_FILE" 2048 2>/dev/null
    
    # Generate CSR
    CLIENT_CSR_FILE=$(mktemp)
    openssl req -new -key "$CLIENT_KEY_FILE" -out "$CLIENT_CSR_FILE" \
        -subj "/C=FR/ST=France/L=Home/O=DaddysHome/OU=Users/CN=$email" 2>/dev/null
    
    # Sign certificate
    CLIENT_CERT_FILE=$(mktemp)
    openssl x509 -req -days $CLIENT_VALIDITY_DAYS \
        -in "$CLIENT_CSR_FILE" \
        -CA "$CA_CERT_FILE" -CAkey "$CA_KEY_FILE" \
        -CAcreateserial -out "$CLIENT_CERT_FILE" 2>/dev/null
    
    # Create PKCS12
    CLIENT_P12_FILE=$(mktemp)
    openssl pkcs12 -export -password pass: \
        -in "$CLIENT_CERT_FILE" \
        -inkey "$CLIENT_KEY_FILE" \
        -certfile "$CA_CERT_FILE" \
        -out "$CLIENT_P12_FILE" 2>/dev/null
    
    # Read files and encode
    CLIENT_KEY=$(cat "$CLIENT_KEY_FILE")
    CLIENT_CERT=$(cat "$CLIENT_CERT_FILE")
    CLIENT_P12=$(base64 < "$CLIENT_P12_FILE")
    
    # Store in Vault
    vault kv put secret/pki/clients/$username \
        cert="$CLIENT_CERT" \
        key="$CLIENT_KEY" \
        p12="$CLIENT_P12" \
        email="$email" \
        created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    
    # Cleanup
    rm -f "$CA_KEY_FILE" "$CA_CERT_FILE" "$CLIENT_KEY_FILE" "$CLIENT_CSR_FILE" "$CLIENT_CERT_FILE" "$CLIENT_P12_FILE"
    
    echo "✅ Certificate for $username stored in Vault"
}

# Functions are defined above and will be available when this script is sourced

# Only run initialization if script is executed directly, not sourced
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    # Generate default admin certificate
    generate_client_cert "admin" "admin@daddyshome.fr"

    echo ""
    echo "🎯 PKI initialization complete!"
    echo ""
    echo "📋 Summary:"
    echo "   CA Certificate: Stored at secret/pki/ca"
    echo "   ESO Token: Stored at secret/tokens/eso-pki"
    echo "   Admin Certificate: Generated"
    echo ""
    echo "📥 Client certificate download:"
    echo "   export VAULT_ADDR=$VAULT_ADDR"
    echo "   vault login  # Use your token or auth method"
    echo "   nas/scripts/download-cert.sh [username]"
    echo ""
    echo "🔄 For External Secrets sync, use this token:"
    echo "   $ESO_TOKEN"
fi  # End of direct execution check

# Always create the download script (whether sourced or executed)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cat > "$SCRIPT_DIR/download-cert.sh" << 'SCRIPT'
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
SCRIPT
chmod +x "$SCRIPT_DIR/download-cert.sh"