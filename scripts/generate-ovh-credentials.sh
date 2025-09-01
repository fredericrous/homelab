#!/bin/bash
# Script to generate OVH API credentials for cert-manager DNS challenge

echo "=== OVH API Credential Generator ==="
echo ""
echo "This script will help you create OVH API credentials for cert-manager"
echo ""
echo "Step 1: Create an application at https://eu.api.ovh.com/createApp/"
echo "        You'll receive:"
echo "        - Application Key"
echo "        - Application Secret"
echo ""
read -p "Enter Application Key: " APP_KEY
read -sp "Enter Application Secret: " APP_SECRET
echo ""

echo ""
echo "Step 2: Generate consumer key with required permissions"
echo ""

# Create request for consumer key with minimal required permissions
RESPONSE=$(curl -s -X POST https://eu.api.ovh.com/1.0/auth/credential \
  -H "X-Ovh-Application: $APP_KEY" \
  -H "Content-type: application/json" \
  -d '{
    "accessRules": [
      {
        "method": "GET",
        "path": "/domain/zone/*"
      },
      {
        "method": "PUT",
        "path": "/domain/zone/*/record/*"
      },
      {
        "method": "POST",
        "path": "/domain/zone/*/record"
      },
      {
        "method": "DELETE",
        "path": "/domain/zone/*/record/*"
      },
      {
        "method": "POST",
        "path": "/domain/zone/*/refresh"
      }
    ],
    "redirection": "https://cert-manager.io/"
  }')

VALIDATION_URL=$(echo $RESPONSE | jq -r '.validationUrl')
CONSUMER_KEY=$(echo $RESPONSE | jq -r '.consumerKey')

if [ "$VALIDATION_URL" = "null" ] || [ -z "$VALIDATION_URL" ]; then
  echo "Error: Failed to generate consumer key"
  echo "Response: $RESPONSE"
  exit 1
fi

echo "Step 3: Validate the consumer key"
echo ""
echo "Open this URL in your browser to validate the consumer key:"
echo "$VALIDATION_URL"
echo ""
read -p "Press Enter after you've validated the consumer key..."

echo ""
echo "=== Your OVH API Credentials ==="
echo ""
echo "Application Key: $APP_KEY"
echo "Application Secret: $APP_SECRET"
echo "Consumer Key: $CONSUMER_KEY"
echo ""
echo "To create the Kubernetes secret, run:"
echo ""
echo "kubectl create secret generic ovh-credentials -n cert-manager \\"
echo "  --from-literal=applicationKey=$APP_KEY \\"
echo "  --from-literal=applicationSecret=$APP_SECRET \\"
echo "  --from-literal=consumerKey=$CONSUMER_KEY"
echo ""
echo "To store in Vault:"
echo "vault kv put secret/ovh-dns \\"
echo "  applicationKey=$APP_KEY \\"
echo "  applicationSecret=$APP_SECRET \\"
echo "  consumerKey=$CONSUMER_KEY"