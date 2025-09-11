#!/bin/bash
# Test dynamic environment substitution

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "🔍 Testing Dynamic Environment Substitution"
echo "==========================================="

# Load .env file
if [ -f "$ROOT_DIR/.env" ]; then
    set -a
    source "$ROOT_DIR/.env"
    set +a
    echo -e "${GREEN}✓ Loaded .env file${NC}"
else
    echo -e "${RED}✗ No .env file found${NC}"
    exit 1
fi

# Test on a specific manifest
TEST_PATH="${1:-manifests/core/vault}"

echo ""
echo "📁 Testing path: $TEST_PATH"
echo ""

# Build manifests and find variables
echo "🔎 Scanning for variables..."
cd "$ROOT_DIR"
MANIFESTS=$(kustomize build "$TEST_PATH" 2>/dev/null || echo "Error building kustomize")
VARS_FOUND=$(echo "$MANIFESTS" | grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' | sed 's/[${}]//g' | sort -u)

if [ -z "$VARS_FOUND" ]; then
    echo -e "${YELLOW}No variables found in manifests${NC}"
    exit 0
fi

echo "📋 Variables found in manifests:"
for var in $VARS_FOUND; do
    if [ -n "${!var:-}" ]; then
        # Mask sensitive values
        if [[ "$var" =~ (TOKEN|SECRET|KEY|PASSWORD) ]]; then
            echo -e "  ${GREEN}✓${NC} $var = <masked>"
        else
            echo -e "  ${GREEN}✓${NC} $var = ${!var}"
        fi
    else
        echo -e "  ${RED}✗${NC} $var = <not set>"
    fi
done

echo ""
echo "🔄 Performing substitution..."
echo ""

# Show a sample of the substitution
echo "Sample output (first resource):"
echo "--------------------------------"
echo "$MANIFESTS" | envsubst | head -n 30

echo ""
echo -e "${GREEN}✅ Test complete!${NC}"
echo ""
echo "💡 Tips:"
echo "  - Missing variables will cause ArgoCD sync to fail"
echo "  - Add missing variables to your .env file"
echo "  - Use \${VAR_NAME} syntax in your YAML files"