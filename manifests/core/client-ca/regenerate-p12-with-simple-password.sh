#!/bin/bash
# Script to regenerate p12 file with simple password for iOS

CLIENT_DIR="./ca/clients"
CA_DIR="./ca"
PASSWORD="daddy"

# Check if client certificate exists
if [ ! -f "$CLIENT_DIR/client1.crt" ] || [ ! -f "$CLIENT_DIR/client1.key" ]; then
    echo "❌ Client certificate files not found!"
    exit 1
fi

# Create new PKCS12 bundle with simple password
echo "🔐 Creating new PKCS12 bundle with password: $PASSWORD"
openssl pkcs12 -export -out $CLIENT_DIR/client1-ios.p12 \
    -inkey $CLIENT_DIR/client1.key -in $CLIENT_DIR/client1.crt \
    -certfile $CA_DIR/ca.crt -passout pass:$PASSWORD

echo "✅ New client1-ios.p12 created!"
echo ""
echo "📱 For iPhone/iOS:"
echo "   1. Email or AirDrop the client1-ios.p12 file to your iPhone"
echo "   2. Open the file and follow the prompts"
echo "   3. When asked for password, enter: $PASSWORD"
echo ""
echo "🔒 Password: $PASSWORD"