#!/bin/bash
# Universal wait script for Kubernetes resources with Ready condition

set -euo pipefail

# Usage
usage() {
  echo "Usage: $0 <resource-type> <resource-name> [timeout-seconds] [namespace]"
  echo ""
  echo "Examples:"
  echo "  $0 deployment nginx 300 default"
  echo "  $0 clustersecretstore nas-vault-backend 180"
  echo "  $0 externalsecret my-secret 60 vault"
  exit 1
}

# Parse arguments
if [ $# -lt 2 ]; then
  usage
fi

RESOURCE_TYPE="$1"
RESOURCE_NAME="$2"
TIMEOUT="${3:-300}"  # Default 5 minutes
NAMESPACE="${4:-}"

# Build namespace flag
NS_FLAG=""
if [ -n "$NAMESPACE" ]; then
  NS_FLAG="-n $NAMESPACE"
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "⏳ Waiting for $RESOURCE_TYPE/$RESOURCE_NAME to be ready..."
[ -n "$NAMESPACE" ] && echo "   Namespace: $NAMESPACE"

# Check if resource supports conditions
if ! kubectl explain "$RESOURCE_TYPE.status.conditions" &>/dev/null; then
  echo -e "${YELLOW}⚠️  Resource type '$RESOURCE_TYPE' doesn't support status conditions${NC}"
  echo "   Falling back to basic existence check..."
  
  if kubectl wait "$RESOURCE_TYPE" "$RESOURCE_NAME" $NS_FLAG \
    --for=jsonpath='{.metadata.name}'="$RESOURCE_NAME" \
    --timeout="${TIMEOUT}s" 2>/dev/null; then
    echo -e "${GREEN}✅ Resource exists${NC}"
    exit 0
  else
    echo -e "${RED}❌ Resource not found after ${TIMEOUT}s${NC}"
    exit 1
  fi
fi

# Try kubectl wait first (most efficient)
echo "   Using kubectl wait (timeout: ${TIMEOUT}s)..."
if kubectl wait "$RESOURCE_TYPE" "$RESOURCE_NAME" $NS_FLAG \
  --for=condition=Ready \
  --timeout="${TIMEOUT}s" 2>&1 | tee /tmp/wait-output.log | grep -q "condition met"; then
  echo -e "${GREEN}✅ $RESOURCE_TYPE/$RESOURCE_NAME is ready!${NC}"
  exit 0
fi

# Check if resource doesn't exist
if grep -q "NotFound" /tmp/wait-output.log || grep -q "doesn't have a resource" /tmp/wait-output.log; then
  echo -e "${RED}❌ $RESOURCE_TYPE/$RESOURCE_NAME not found${NC}"
  exit 1
fi

# Fallback to manual polling with detailed information
echo -e "${YELLOW}   kubectl wait didn't succeed, polling manually...${NC}"
START_TIME=$(date +%s)

while true; do
  # Check if resource exists
  if ! kubectl get "$RESOURCE_TYPE" "$RESOURCE_NAME" $NS_FLAG &>/dev/null; then
    echo "   Resource doesn't exist yet..."
    sleep 5
    continue
  fi
  
  # Get all conditions
  CONDITIONS=$(kubectl get "$RESOURCE_TYPE" "$RESOURCE_NAME" $NS_FLAG -o json 2>/dev/null | \
    jq -r '.status.conditions[]? | "\(.type): \(.status) (\(.reason // ""))"' 2>/dev/null || echo "")
  
  # Get Ready condition specifically
  READY_STATUS=$(kubectl get "$RESOURCE_TYPE" "$RESOURCE_NAME" $NS_FLAG \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  READY_REASON=$(kubectl get "$RESOURCE_TYPE" "$RESOURCE_NAME" $NS_FLAG \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "")
  READY_MESSAGE=$(kubectl get "$RESOURCE_TYPE" "$RESOURCE_NAME" $NS_FLAG \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
  
  # Display current status
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))
  
  echo "   [${ELAPSED}s] Ready: ${READY_STATUS:-Unknown}"
  [ -n "$READY_REASON" ] && echo "   Reason: $READY_REASON"
  [ -n "$READY_MESSAGE" ] && echo "   Message: $READY_MESSAGE"
  
  # Show all conditions if available
  if [ -n "$CONDITIONS" ]; then
    echo "   All conditions:"
    echo "$CONDITIONS" | sed 's/^/     /'
  fi
  
  echo ""
  
  # Check if ready
  if [ "$READY_STATUS" = "True" ]; then
    echo -e "${GREEN}✅ $RESOURCE_TYPE/$RESOURCE_NAME is ready!${NC}"
    exit 0
  fi
  
  # Check timeout
  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo -e "${RED}❌ Timeout after ${TIMEOUT}s waiting for $RESOURCE_TYPE/$RESOURCE_NAME${NC}"
    echo ""
    echo "Final status:"
    kubectl get "$RESOURCE_TYPE" "$RESOURCE_NAME" $NS_FLAG -o yaml | grep -A30 "^status:" || true
    echo ""
    echo "Troubleshooting:"
    echo "  kubectl describe $RESOURCE_TYPE $RESOURCE_NAME $NS_FLAG"
    echo "  kubectl get events $NS_FLAG --field-selector involvedObject.name=$RESOURCE_NAME"
    exit 1
  fi
  
  # Show remaining time
  REMAINING=$((TIMEOUT - ELAPSED))
  echo "   (${REMAINING}s remaining)"
  
  sleep 5
done