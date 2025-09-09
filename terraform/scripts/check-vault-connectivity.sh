#!/bin/bash
set -euo pipefail

# Check if we can reach QNAP Vault
VAULT_ADDR="${VAULT_ADDR:-http://192.168.1.42:61200}"
echo "🔍 Checking connectivity to QNAP Vault at $VAULT_ADDR..."

# Try to reach Vault with a timeout
if ! curl -s --connect-timeout 5 --max-time 10 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; then
    echo "❌ Cannot reach QNAP Vault at $VAULT_ADDR"
    echo ""
    echo "Possible reasons:"
    echo "1. You're not connected to your home network"
    echo "2. QNAP Vault is not running" 
    echo "3. The IP address has changed"
    echo ""
    echo "To fix this:"
    echo "1. Connect to your home network (VPN or local)"
    echo "2. Verify QNAP Vault is accessible:"
    echo "   curl $VAULT_ADDR/v1/sys/health"
    echo "3. Or provide the transit token manually:"
    echo "   export K8S_VAULT_TRANSIT_TOKEN=<your-transit-token>"
    exit 1
fi

echo "✅ QNAP Vault is reachable"

# Now check if we can authenticate
if [ -n "$QNAP_VAULT_TOKEN" ]; then
    export VAULT_TOKEN="$QNAP_VAULT_TOKEN"
    if ! vault token lookup &>/dev/null; then
        echo "❌ QNAP_VAULT_TOKEN is invalid or expired"
        echo "   Please check your token and try again"
        exit 1
    fi
    echo "✅ QNAP_VAULT_TOKEN is valid"
else
    echo "⚠️  QNAP_VAULT_TOKEN not set"
fi