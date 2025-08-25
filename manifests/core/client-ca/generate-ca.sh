#!/bin/bash
set -e

# Create directory for CA files
CA_DIR="./ca"
mkdir -p $CA_DIR

echo "🔐 Creating Certificate Authority for daddyshome.fr..."

# Generate CA private key
openssl genrsa -out $CA_DIR/ca.key 4096

# Generate CA certificate
openssl req -new -x509 -days 3650 -key $CA_DIR/ca.key -out $CA_DIR/ca.crt \
    -subj "/C=FR/ST=France/L=Home/O=DaddysHome/OU=IT/CN=DaddysHome CA"

echo "✅ CA certificate created at $CA_DIR/ca.crt"

# Create Kubernetes secret with CA certificate
kubectl create secret generic client-ca-cert \
    --from-file=ca.crt=$CA_DIR/ca.crt \
    --namespace=ingress-nginx \
    --dry-run=client -o yaml > client-ca-secret.yaml

echo "📦 Kubernetes secret manifest created at client-ca-secret.yaml"

# Generate a sample client certificate
CLIENT_DIR="$CA_DIR/clients"
mkdir -p $CLIENT_DIR

echo ""
echo "🔑 Generating sample client certificate..."

# Generate client private key
openssl genrsa -out $CLIENT_DIR/client1.key 2048

# Generate client certificate request
openssl req -new -key $CLIENT_DIR/client1.key -out $CLIENT_DIR/client1.csr \
    -subj "/C=FR/ST=France/L=Home/O=DaddysHome/OU=Users/CN=admin@daddyshome.fr"

# Sign client certificate with CA
openssl x509 -req -days 365 -in $CLIENT_DIR/client1.csr -CA $CA_DIR/ca.crt -CAkey $CA_DIR/ca.key \
    -CAcreateserial -out $CLIENT_DIR/client1.crt

# Create PKCS12 bundle for easy import (without password)
openssl pkcs12 -export -out $CLIENT_DIR/client1.p12 \
    -inkey $CLIENT_DIR/client1.key -in $CLIENT_DIR/client1.crt \
    -certfile $CA_DIR/ca.crt -passout pass:

echo "✅ Client certificate created:"
echo "   - Certificate: $CLIENT_DIR/client1.crt"
echo "   - Private key: $CLIENT_DIR/client1.key"
echo "   - PKCS12 bundle: $CLIENT_DIR/client1.p12 (password: changeme)"
echo ""
echo "📋 Import client1.p12 into your browser/system to authenticate"