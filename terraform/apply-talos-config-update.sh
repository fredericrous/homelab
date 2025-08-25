#!/bin/bash
# Script to apply Talos configuration updates without recreating VMs

set -e

echo "Applying Talos configuration updates..."

# Change to terraform directory
cd "$(dirname "$0")"

# Apply only the Talos configuration resources
terraform apply \
  -target=talos_machine_configuration_apply.nodes \
  -auto-approve

echo "Configuration updates applied. The nodes will restart containerd to apply the new registry configuration."
echo ""
echo "You can verify the configuration was applied by checking if pods can pull images from Harbor:"
echo "kubectl -n stremio delete pod -l app=stremio-web"
echo "kubectl -n stremio get pods -w"