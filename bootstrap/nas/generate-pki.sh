#!/bin/bash
# PKI generation script for NAS cluster
# Sets up proper PKI engine with root CA and client certificate issuing

set -e

# Configuration
VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
CA_VALIDITY_HOURS=87600  # 10 years
CLIENT_VALIDITY_HOURS=8760  # 1 year

echo "🔐 Initializing PKI in NAS Vault..."

# Authenticate to Vault if needed
if ! vault token lookup &>/dev/null 2>&1; then
    echo "❌ Not authenticated to Vault"
    echo "   Run: vault login <token>"
    exit 1
fi

# Ensure KV v2 is enabled at secret/
if ! vault secrets list | grep -q "^secret/"; then
    echo "📦 Enabling KV v2 secrets engine..."
    vault secrets enable -path=secret kv-v2
fi

# Enable PKI engine for proper certificate issuing
if ! vault secrets list | grep -q "^pki/"; then
    echo "🔐 Enabling PKI secrets engine..."
    vault secrets enable -path=pki pki
    vault secrets tune -max-lease-ttl=${CA_VALIDITY_HOURS}h pki
fi

# Check if root CA already exists in PKI
if vault read pki/cert/ca >/dev/null 2>&1; then
    echo "✅ Root CA already exists in PKI engine"
    CA_EXISTS=true
else
    echo "🆕 Generating root CA in PKI engine..."
    
    # Generate root CA
    vault write pki/root/generate/internal \
        common_name="DaddysHome Root CA" \
        country="FR" \
        locality="Home" \
        organization="DaddysHome" \
        ou="IT" \
        ttl=${CA_VALIDITY_HOURS}h
    
    echo "✅ Root CA generated in PKI engine"
    CA_EXISTS=false
fi

# Configure PKI URLs
vault write pki/config/urls \
    issuing_certificates="$VAULT_ADDR/v1/pki/ca" \
    crl_distribution_points="$VAULT_ADDR/v1/pki/crl"

# Sync CA certificate to secret/ for ESO compatibility
echo "📋 Syncing CA certificate to secret/pki/ca for ESO..."
CA_CERT=$(vault read -field=certificate pki/cert/ca)
vault kv put secret/pki/ca "ca.crt=$CA_CERT"

# Create PKI role for client certificates
echo "🎭 Creating PKI role for client certificates..."
vault write pki/roles/client-cert \
    allowed_domains="daddyshome.fr" \
    allow_subdomains=true \
    allow_bare_domains=false \
    allow_localhost=false \
    allow_ip_sans=false \
    key_type=rsa \
    key_bits=2048 \
    key_usage="digital_signature,key_encipherment" \
    ext_key_usage="client_auth" \
    ttl=${CLIENT_VALIDITY_HOURS}h \
    max_ttl=${CLIENT_VALIDITY_HOURS}h

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

# Function to generate client certificate using PKI engine
generate_client_cert() {
    local username=$1
    local email=$2
    
    if vault kv get secret/pki/clients/$username >/dev/null 2>&1; then
        echo "⚠️  Certificate for $username already exists"
        return 0
    fi
    
    echo "🔑 Generating certificate for $username ($email)..."
    
    # Issue certificate from PKI engine
    CERT_RESPONSE=$(vault write -format=json pki/issue/client-cert \
        common_name="$email" \
        ttl=${CLIENT_VALIDITY_HOURS}h)
    
    # Extract certificate data
    CLIENT_CERT=$(echo "$CERT_RESPONSE" | jq -r '.data.certificate')
    CLIENT_KEY=$(echo "$CERT_RESPONSE" | jq -r '.data.private_key')
    ISSUING_CA=$(echo "$CERT_RESPONSE" | jq -r '.data.issuing_ca')
    SERIAL_NUMBER=$(echo "$CERT_RESPONSE" | jq -r '.data.serial_number')
    
    # Create PKCS12 file
    CLIENT_CERT_FILE=$(mktemp)
    CLIENT_KEY_FILE=$(mktemp)
    CA_CERT_FILE=$(mktemp)
    CLIENT_P12_FILE=$(mktemp)
    
    echo "$CLIENT_CERT" > "$CLIENT_CERT_FILE"
    echo "$CLIENT_KEY" > "$CLIENT_KEY_FILE"
    echo "$ISSUING_CA" > "$CA_CERT_FILE"
    
    # Create PKCS12
    openssl pkcs12 -export -password pass: \
        -in "$CLIENT_CERT_FILE" \
        -inkey "$CLIENT_KEY_FILE" \
        -certfile "$CA_CERT_FILE" \
        -out "$CLIENT_P12_FILE" 2>/dev/null
    
    CLIENT_P12=$(base64 < "$CLIENT_P12_FILE")
    
    # Store in Vault for backward compatibility with existing sync
    vault kv put secret/pki/clients/$username \
        cert="$CLIENT_CERT" \
        key="$CLIENT_KEY" \
        p12="$CLIENT_P12" \
        email="$email" \
        serial="$SERIAL_NUMBER" \
        created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    
    # Cleanup
    rm -f "$CLIENT_CERT_FILE" "$CLIENT_KEY_FILE" "$CA_CERT_FILE" "$CLIENT_P12_FILE"
    
    echo "✅ Certificate for $username issued via PKI and stored in Vault"
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