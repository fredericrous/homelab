#!/bin/bash

# Create TLS secret managers for all services
# This script creates TLS secrets in istio-ingress namespace for mTLS Gateway access

SERVICES=("plex" "nextcloud")

for SERVICE in "${SERVICES[@]}"; do
  echo "Setting up Istio TLS for $SERVICE..."
  
  # Wait for certificate to be ready
  kubectl wait --for=condition=Ready certificate ${SERVICE}-tls -n $SERVICE --timeout=300s
  
  # Clean up old secrets if they exist
  kubectl delete secret ${SERVICE}-tls-secret -n $SERVICE --ignore-not-found=true
  kubectl delete secret ${SERVICE}-tls-secret -n istio-ingress --ignore-not-found=true
  
  # Get required data
  TLS_CRT=$(kubectl get secret ${SERVICE}-tls -n $SERVICE -o jsonpath='{.data.tls\.crt}' | base64 -d)
  TLS_KEY=$(kubectl get secret ${SERVICE}-tls -n $SERVICE -o jsonpath='{.data.tls\.key}' | base64 -d)
  CA_CRT=$(kubectl get secret client-ca-cert -n istio-ingress -o jsonpath='{.data.ca\.crt}' | base64 -d)
  
  # Create temporary files
  echo "$TLS_CRT" > /tmp/${SERVICE}_tls.crt
  echo "$TLS_KEY" > /tmp/${SERVICE}_tls.key
  CA_CRT_B64=$(echo -n "$CA_CRT" | base64 | tr -d '\n')
  
  # Create secret in istio-ingress namespace (where Gateway pod runs)
  kubectl create secret tls ${SERVICE}-tls-secret -n istio-ingress \
    --cert=/tmp/${SERVICE}_tls.crt \
    --key=/tmp/${SERVICE}_tls.key
  
  kubectl patch secret ${SERVICE}-tls-secret -n istio-ingress \
    --patch="{\"data\":{\"cacert\":\"$CA_CRT_B64\"}}"
  
  kubectl label secret ${SERVICE}-tls-secret -n istio-ingress \
    istio/tls-secret=true \
    app.kubernetes.io/managed-by=flux
  
  # Also create in service namespace for consistency
  kubectl create secret tls ${SERVICE}-tls-secret -n $SERVICE \
    --cert=/tmp/${SERVICE}_tls.crt \
    --key=/tmp/${SERVICE}_tls.key
  
  kubectl patch secret ${SERVICE}-tls-secret -n $SERVICE \
    --patch="{\"data\":{\"cacert\":\"$CA_CRT_B64\"}}"
  
  kubectl label secret ${SERVICE}-tls-secret -n $SERVICE \
    istio/tls-secret=true \
    app.kubernetes.io/managed-by=flux
  
  # Clean up temporary files
  rm -f /tmp/${SERVICE}_tls.crt /tmp/${SERVICE}_tls.key
  
  echo "✅ Completed Istio TLS setup for $SERVICE"
done

# Handle Nextcloud mobile (SIMPLE TLS, no mTLS)
echo "Setting up Istio TLS for nextcloud-mobile (no mTLS)..."

kubectl wait --for=condition=Ready certificate nextcloud-mobile-tls -n nextcloud --timeout=300s

kubectl delete secret nextcloud-mobile-tls-secret -n istio-ingress --ignore-not-found=true

# Get mobile certificate data (no CA needed for SIMPLE mode)
TLS_CRT=$(kubectl get secret nextcloud-mobile-tls -n nextcloud -o jsonpath='{.data.tls\.crt}' | base64 -d)
TLS_KEY=$(kubectl get secret nextcloud-mobile-tls -n nextcloud -o jsonpath='{.data.tls\.key}' | base64 -d)

# Create temporary files
echo "$TLS_CRT" > /tmp/nextcloud_mobile_tls.crt
echo "$TLS_KEY" > /tmp/nextcloud_mobile_tls.key

# Create secret in istio-ingress namespace (SIMPLE TLS, no cacert needed)
kubectl create secret tls nextcloud-mobile-tls-secret -n istio-ingress \
  --cert=/tmp/nextcloud_mobile_tls.crt \
  --key=/tmp/nextcloud_mobile_tls.key

kubectl label secret nextcloud-mobile-tls-secret -n istio-ingress \
  istio/tls-secret=true \
  app.kubernetes.io/managed-by=flux

# Clean up
rm -f /tmp/nextcloud_mobile_tls.crt /tmp/nextcloud_mobile_tls.key

echo "✅ Completed Istio TLS setup for nextcloud-mobile"

echo "🎉 All services configured for Istio Gateway with mTLS!"