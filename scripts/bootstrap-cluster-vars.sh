#!/bin/bash
# Bootstrap script to create cluster variables secret for FluxCD
# This should be run after cluster creation
# Reads all variables from .env and creates a secret with each as a property

set -euo pipefail
trap 'echo ""; echo "❌ VM readiness check interrupted by user"; exit 130' INT TERM
trap 'echo "DEBUG: Script failed at line $LINENO"' ERR

# Check if .env file exists
if [ ! -f .env ]; then
  echo "ERROR: .env file not found"
  exit 1
fi

echo "Creating cluster-vars secret from .env variables..."

# Build kubectl command with all env vars as literal values
KUBECTL_CMD="kubectl create secret generic cluster-vars --namespace=flux-system"

# Process .env file line by line
while IFS= read -r line; do
  # Skip empty lines and comments
  if [[ -z "$line" || "$line" =~ ^[[:space:]]*# || ! "$line" =~ = ]]; then
    continue
  fi

  # Extract key and value
  key="${line%%=*}"
  value="${line#*=}"

  # Trim whitespace from key
  key="$(echo -n "$key" | xargs)"

  # Remove quotes from value if present
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"

  # Skip if key or value is empty
  if [[ -z "$key" || -z "$value" ]]; then
    continue
  fi

  # Add to kubectl command
  KUBECTL_CMD="$KUBECTL_CMD --from-literal=$key=\"$value\""
done < .env

# Debug: Show number of variables found
NUM_VARS=$(echo "$KUBECTL_CMD" | grep -o "\-\-from-literal" | wc -l)
echo "Found $NUM_VARS variables to add to secret"

# Execute the command with dry-run first, then apply with annotations
eval "$KUBECTL_CMD --dry-run=client -o yaml" | \
  kubectl annotate -f - \
    --local \
    --overwrite \
    -o yaml \
    reflector.v1.k8s.emberstack.com/reflection-allowed="true" \
    reflector.v1.k8s.emberstack.com/reflection-auto-enabled="true" | \
  kubectl apply -f -

# Get the list of variables for confirmation
echo ""
echo "✅ Cluster variables secret created with the following variables:"
kubectl get secret cluster-vars -n flux-system -o jsonpath='{.data}' | jq -r 'keys[]' 2>/dev/null || \
  kubectl get secret cluster-vars -n flux-system -o jsonpath='{.data}' | sed 's/.*{\(.*\)}.*/\1/' | tr ',' '\n' | sed 's/"//g' | cut -d: -f1
