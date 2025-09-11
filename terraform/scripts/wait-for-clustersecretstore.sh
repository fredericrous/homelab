#!/bin/bash
# Improved ClusterSecretStore wait script

set -euo pipefail

# Configuration
RESOURCE_NAME="${1:-nas-vault-backend}"
TIMEOUT="${2:-300}"  # 5 minutes default
NAMESPACE="${3:-}"   # Empty for cluster-scoped resources

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "⏳ Waiting for ClusterSecretStore '$RESOURCE_NAME' to be ready..."

# First, wait for the resource to exist
echo "   Waiting for resource to be created..."
WAIT_EXISTS=0
while ! kubectl get clustersecretstore "$RESOURCE_NAME" &>/dev/null; do
  sleep 2
  WAIT_EXISTS=$((WAIT_EXISTS + 2))
  if [ $WAIT_EXISTS -ge 60 ]; then
    echo -e "${RED}❌ ClusterSecretStore '$RESOURCE_NAME' not found after 60 seconds${NC}"
    exit 1
  fi
done
echo -e "${GREEN}✓ Resource exists${NC}"

# Use kubectl wait with a timeout
echo "   Waiting for Ready condition..."
if kubectl wait clustersecretstore "$RESOURCE_NAME" \
  --for=condition=Ready \
  --timeout="${TIMEOUT}s" 2>/dev/null; then
  echo -e "${GREEN}✅ ClusterSecretStore '$RESOURCE_NAME' is ready!${NC}"
  exit 0
else
  # If wait failed, let's get more details
  echo -e "${YELLOW}⚠️  kubectl wait timed out or failed. Checking status...${NC}"
fi

# Fallback: Poll with detailed status
START_TIME=$(date +%s)
while true; do
  # Get all conditions
  CONDITIONS=$(kubectl get clustersecretstore "$RESOURCE_NAME" -o json 2>/dev/null | \
    jq -r '.status.conditions[]? | "\(.type): \(.status) (\(.reason // ""))"' || echo "No conditions found")
  
  # Check specific Ready condition
  READY_STATUS=$(kubectl get clustersecretstore "$RESOURCE_NAME" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  
  # Get provider status if available
  PROVIDER_STATUS=$(kubectl get clustersecretstore "$RESOURCE_NAME" \
    -o jsonpath='{.status.conditions[?(@.type=="SecretStoreProvider")].status}' 2>/dev/null || echo "Unknown")
  
  echo "   Status check at $(date +%H:%M:%S):"
  echo "   - Ready: $READY_STATUS"
  echo "   - Provider: $PROVIDER_STATUS"
  
  if [ -n "$CONDITIONS" ] && [ "$CONDITIONS" != "No conditions found" ]; then
    echo "   - All conditions:"
    echo "$CONDITIONS" | sed 's/^/     /'
  fi
  
  # Check if ready
  if [ "$READY_STATUS" = "True" ]; then
    echo -e "${GREEN}✅ ClusterSecretStore '$RESOURCE_NAME' is ready!${NC}"
    exit 0
  fi
  
  # Check for permanent failures
  ERROR_MESSAGE=$(kubectl get clustersecretstore "$RESOURCE_NAME" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
  
  if [ -n "$ERROR_MESSAGE" ]; then
    echo "   - Message: $ERROR_MESSAGE"
  fi
  
  # Check timeout
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))
  
  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo -e "${RED}❌ Timeout waiting for ClusterSecretStore after ${TIMEOUT} seconds${NC}"
    echo "   Final status:"
    kubectl get clustersecretstore "$RESOURCE_NAME" -o yaml | grep -A20 "^status:" || true
    echo ""
    echo "   Troubleshooting commands:"
    echo "   - kubectl describe clustersecretstore $RESOURCE_NAME"
    echo "   - kubectl logs -n external-secrets deploy/external-secrets"
    echo "   - kubectl get secret -n external-secrets | grep vault"
    exit 1
  fi
  
  # Progress indicator
  REMAINING=$((TIMEOUT - ELAPSED))
  echo "   (${ELAPSED}s elapsed, ${REMAINING}s remaining)"
  echo ""
  
  sleep 5
done