#!/bin/bash
set -e

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <username> <email>"
    echo "Example: $0 john john@daddyshome.fr"
    exit 1
fi

USERNAME=$1
EMAIL=$2
CA_DIR="./ca"
CLIENT_DIR="$CA_DIR/clients"

if [ ! -f "$CA_DIR/ca.crt" ] || [ ! -f "$CA_DIR/ca.key" ]; then
    echo "❌ CA certificate not found. Run generate-ca.sh first."
    exit 1
fi

mkdir -p $CLIENT_DIR

echo "🔑 Generating client certificate for $USERNAME ($EMAIL)..."

# Generate client private key
openssl genrsa -out $CLIENT_DIR/$USERNAME.key 2048

# Generate client certificate request
openssl req -new -key $CLIENT_DIR/$USERNAME.key -out $CLIENT_DIR/$USERNAME.csr \
    -subj "/C=FR/ST=France/L=Home/O=DaddysHome/OU=Users/CN=$EMAIL"

# Sign client certificate with CA
openssl x509 -req -days 365 -in $CLIENT_DIR/$USERNAME.csr -CA $CA_DIR/ca.crt -CAkey $CA_DIR/ca.key \
    -CAcreateserial -out $CLIENT_DIR/$USERNAME.crt

# Create PKCS12 bundle for easy import (without password)
echo "📦 Creating PKCS12 bundle..."
openssl pkcs12 -export -out $CLIENT_DIR/$USERNAME.p12 \
    -inkey $CLIENT_DIR/$USERNAME.key -in $CLIENT_DIR/$USERNAME.crt \
    -certfile $CA_DIR/ca.crt -passout pass:

# Clean up CSR
rm $CLIENT_DIR/$USERNAME.csr

echo ""
echo "✅ Client certificate created for $USERNAME:"
echo "   - Certificate: $CLIENT_DIR/$USERNAME.crt"
echo "   - Private key: $CLIENT_DIR/$USERNAME.key"
echo "   - PKCS12 bundle: $CLIENT_DIR/$USERNAME.p12"
echo ""
echo "📋 Instructions:"
echo "1. Send $CLIENT_DIR/$USERNAME.p12 to the user"
echo "2. Import the .p12 file into their browser/system"
echo "3. No password is required for import"