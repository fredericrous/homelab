#!/bin/bash
# Prepare deployment by substituting environment variables in templates
# This allows keeping sensitive data out of Git

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "🚀 Preparing deployment configuration..."

# Check for .env file
if [ ! -f "$ROOT_DIR/.env" ]; then
    echo -e "${RED}❌ .env file not found!${NC}"
    echo "Please copy .env.example to .env and configure it:"
    echo "  cp .env.example .env"
    exit 1
fi

# Load environment variables
set -a
source "$ROOT_DIR/.env"
set +a

# Validate required variables
required_vars=(
    "CLUSTER_DOMAIN"
    "QNAP_VAULT_ADDR"
)

missing_vars=()
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        missing_vars+=("$var")
    fi
done

if [ ${#missing_vars[@]} -ne 0 ]; then
    echo -e "${RED}❌ Missing required environment variables:${NC}"
    printf '%s\n' "${missing_vars[@]}"
    exit 1
fi

echo -e "${GREEN}✓ Environment variables loaded${NC}"

# Create build directory
BUILD_DIR="$ROOT_DIR/.build"
mkdir -p "$BUILD_DIR"

# Copy manifests to build directory
echo "📁 Copying manifests to build directory..."
rsync -a --delete \
    --exclude='.git' \
    --exclude='.build' \
    --exclude='*.example' \
    --exclude='*.tmpl' \
    "$ROOT_DIR/manifests/" "$BUILD_DIR/"

# Process templates
echo "🔄 Processing templates..."

# Find all .tmpl files and process them
find "$BUILD_DIR" -name "*.tmpl" -type f | while read -r template; do
    output="${template%.tmpl}"
    echo "  - Processing: ${template#$BUILD_DIR/}"
    
    # Use envsubst to replace variables
    envsubst < "$template" > "$output"
    
    # Remove template file
    rm "$template"
done

# Update specific files that need domain substitution
echo "🔧 Updating domain references..."

# Replace example.com with actual domain in all YAML files
find "$BUILD_DIR" -name "*.yaml" -type f -exec sed -i'' -e "s/example\.com/$CLUSTER_DOMAIN/g" {} \;
find "$BUILD_DIR" -name "*.yaml" -type f -exec sed -i'' -e "s/yourdomain\.com/$CLUSTER_DOMAIN/g" {} \;

# Update QNAP vault address
find "$BUILD_DIR" -name "*.yaml" -type f -exec sed -i'' -e "s|http://nas\.local:8200|$QNAP_VAULT_ADDR|g" {} \;
find "$BUILD_DIR" -name "*.yaml" -type f -exec sed -i'' -e "s|http://YOUR-NAS-IP:8200|$QNAP_VAULT_ADDR|g" {} \;

echo -e "${GREEN}✅ Deployment configuration prepared!${NC}"
echo ""
echo "📋 Build directory: $BUILD_DIR"
echo ""
echo "You can now:"
echo "1. Review the generated files in $BUILD_DIR"
echo "2. Apply them manually: kubectl apply -k $BUILD_DIR/core/vault"
echo "3. Or update ArgoCD to point to the build directory"
echo ""
echo -e "${YELLOW}⚠️  Note: The build directory is temporary and not in Git${NC}"
echo "    Re-run this script after any manifest changes"