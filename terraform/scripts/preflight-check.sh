#!/bin/bash
# Pre-flight checks for Kubernetes cluster deployment

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🔍 Running pre-flight checks..."
echo "==============================="

CHECKS_PASSED=true

# Check 1: Terraform installed
echo -n "Checking Terraform... "
if command -v terraform &>/dev/null; then
    VERSION=$(terraform version -json | jq -r '.terraform_version' 2>/dev/null || echo "unknown")
    echo -e "${GREEN}✓${NC} (version: $VERSION)"
else
    echo -e "${RED}✗${NC} Terraform not found"
    echo "  Install from: https://www.terraform.io/downloads"
    CHECKS_PASSED=false
fi

# Check 2: Required CLI tools
for tool in kubectl talosctl jq curl; do
    echo -n "Checking $tool... "
    if command -v $tool &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC} $tool not found"
        CHECKS_PASSED=false
    fi
done

# Check 3: QNAP Vault connectivity
echo -n "Checking QNAP Vault connectivity... "
if curl -s -f http://192.168.1.42:61200/v1/sys/health &>/dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${YELLOW}⚠${NC} Cannot reach QNAP Vault"
    echo "  Make sure QNAP services are deployed first"
    CHECKS_PASSED=false
fi

# Check 4: QNAP Vault Token (removed - handled by prereq task)

# Check 5: Proxmox credentials
echo -n "Checking terraform.tfvars... "
if [ -f "terraform.tfvars" ]; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC} Not found"
    echo "  Copy and configure: cp terraform.tfvars.example terraform.tfvars"
    CHECKS_PASSED=false
fi

# Check 6: SSH key
echo -n "Checking SSH key... "
if [ -f "$HOME/.ssh/id_ed25519.pub" ] || [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${YELLOW}⚠${NC} No SSH key found"
    echo "  Generate one: ssh-keygen -t ed25519"
fi

# Check 7: Network connectivity to Proxmox
if [ -f "terraform.tfvars" ]; then
    echo -n "Checking Proxmox connectivity... "
    PROXMOX_IP=$(grep proxmox_api_url terraform.tfvars 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || echo "")
    if [ -n "$PROXMOX_IP" ]; then
        if ping -c 1 -W 2 "$PROXMOX_IP" &>/dev/null; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${RED}✗${NC} Cannot reach Proxmox at $PROXMOX_IP"
            CHECKS_PASSED=false
        fi
    else
        echo -e "${YELLOW}⚠${NC} Cannot determine Proxmox IP"
    fi
fi

# Check 8: OVH Credentials for Let's Encrypt
echo -n "Checking OVH credentials... "
MISSING_OVH_VARS=()
if [ -z "${OVH_APPLICATION_KEY:-}" ]; then
    MISSING_OVH_VARS+=("OVH_APPLICATION_KEY")
fi
if [ -z "${OVH_APPLICATION_SECRET:-}" ]; then
    MISSING_OVH_VARS+=("OVH_APPLICATION_SECRET")
fi
if [ -z "${OVH_CONSUMER_KEY:-}" ]; then
    MISSING_OVH_VARS+=("OVH_CONSUMER_KEY")
fi

if [ ${#MISSING_OVH_VARS[@]} -eq 0 ]; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC} Missing required environment variables"
    echo "  Missing: ${MISSING_OVH_VARS[*]}"
    echo "  These are REQUIRED for Let's Encrypt SSL certificates"
    echo "  Export them before running deploy:"
    echo "    export OVH_APPLICATION_KEY=<your-key>"
    echo "    export OVH_APPLICATION_SECRET=<your-secret>"
    echo "    export OVH_CONSUMER_KEY=<your-consumer-key>"
    CHECKS_PASSED=false
fi

echo ""
echo "==============================="

if [ "$CHECKS_PASSED" = true ]; then
    echo -e "${GREEN}✅ All checks passed!${NC}"
    echo "Ready to deploy. Run: task deploy"
    exit 0
else
    echo -e "${RED}❌ Some checks failed${NC}"
    echo "Please fix the issues above before deploying."
    exit 1
fi