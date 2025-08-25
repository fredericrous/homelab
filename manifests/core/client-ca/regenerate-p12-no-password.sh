#!/bin/bash
# Script to regenerate p12 file without password

CLIENT_DIR="./ca/clients"
CA_DIR="./ca"

# Check if client certificate exists
if [ ! -f "$CLIENT_DIR/client1.crt" ] || [ ! -f "$CLIENT_DIR/client1.key" ]; then
    echo "❌ Client certificate files not found!"
    echo "   Expected: $CLIENT_DIR/client1.crt and $CLIENT_DIR/client1.key"
    exit 1
fi

# Backup existing p12 if it exists
if [ -f "$CLIENT_DIR/client1.p12" ]; then
    mv "$CLIENT_DIR/client1.p12" "$CLIENT_DIR/client1.p12.backup"
    echo "📋 Backed up existing p12 to client1.p12.backup"
fi

# Create new PKCS12 bundle without password
echo "🔐 Creating new PKCS12 bundle without password..."
openssl pkcs12 -export -out $CLIENT_DIR/client1.p12 \
    -inkey $CLIENT_DIR/client1.key -in $CLIENT_DIR/client1.crt \
    -certfile $CA_DIR/ca.crt -passout pass:

echo "✅ New client1.p12 created without password!"
echo ""
echo "📱 For iPhone/iOS:"
echo "   1. Email or AirDrop the client1.p12 file to your iPhone"
echo "   2. Open the file and follow the prompts"
echo "   3. When asked for password, leave it empty and tap Next/Done"
echo ""
echo "⚠️  Note: Some iOS versions require at least a 4-character password."
echo "   If empty password doesn't work, regenerate with a simple password like '1234'"