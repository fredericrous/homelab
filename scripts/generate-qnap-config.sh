#!/bin/bash
# Generate QNAP Vault configuration from environment

QNAP_VAULT_ADDR="${QNAP_VAULT_ADDR:-http://192.168.1.42:61200}"

echo "📝 Generating QNAP Vault configuration..."
echo "   QNAP_VAULT_ADDR: $QNAP_VAULT_ADDR"

# Generate ConfigMap patch with structured configuration
cat > manifests/core/vault/qnap-vault-config-patch.yaml <<EOF
# Auto-generated patch - DO NOT EDIT MANUALLY
# Generated from QNAP_VAULT_ADDR environment variable
apiVersion: v1
kind: ConfigMap
metadata:
  name: qnap-vault-config
  namespace: vault
data:
  config.yaml: |
    transit:
      address: "$QNAP_VAULT_ADDR"
      mountPath: "transit"
      keyName: "autounseal"
      tlsSkipVerify: true
EOF

# Generate patch for external-secrets ClusterSecretStore
cat > manifests/core/external-secrets-operator/clustersecretstore-nas-vault-patch.yaml <<EOF
# Auto-generated patch - DO NOT EDIT MANUALLY
# Generated from QNAP_VAULT_ADDR environment variable
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: nas-vault-backend
spec:
  provider:
    vault:
      server: "$QNAP_VAULT_ADDR"
EOF

echo "✅ Configuration files generated"
echo ""
echo "Generated files:"
echo "  - manifests/core/vault/qnap-vault-config-patch.yaml"
echo "  - manifests/core/external-secrets-operator/clustersecretstore-nas-vault-patch.yaml"