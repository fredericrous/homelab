#!/bin/bash
# Bootstrap script to create cluster variables secret for FluxCD
# This should be run after cluster creation

set -euo pipefail

# Load from .env file if exists
if [ -f .env ]; then
  source .env
fi

# Verify required variables
if [ -z "${PLEX_CLAIM_TOKEN:-}" ]; then
  echo "ERROR: PLEX_CLAIM_TOKEN not found in .env file"
  echo "Please add PLEX_CLAIM_TOKEN to your .env file"
  exit 1
fi

echo "Creating cluster-vars secret in flux-system namespace..."

# Create the secret with all cluster variables
kubectl create secret generic cluster-vars \
  --namespace=flux-system \
  --from-literal=PLEX_CLAIM_TOKEN="$PLEX_CLAIM_TOKEN" \
  --save-config=true 2>/dev/null || \
kubectl create secret generic cluster-vars \
  --namespace=flux-system \
  --from-literal=PLEX_CLAIM_TOKEN="$PLEX_CLAIM_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "✅ Cluster variables secret created successfully!"