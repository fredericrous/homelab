#!/bin/bash
# Staged deployment script following ChatGPT recommendations
# This ensures proper installation to disk before bootstrap

set -euo pipefail

echo "🚀 Starting staged Talos deployment..."

cd terraform

# Initialize if needed
if [ ! -d ".terraform" ]; then
    echo "🔧 Initializing Terraform..."
    terraform init
fi

# Stage 1: Infrastructure only (VMs + ISO)
echo "📦 Stage 1: Creating infrastructure (VMs + ISO)..."
echo "  Using parallelism=1 to avoid Proxmox provider conflicts"
terraform apply -auto-approve -parallelism=1 \
    -target=data.external.schematic_base \
    -target=data.external.schematic_gpu \
    -target=proxmox_virtual_environment_download_file.talos_iso \
    -target=module.vms

# Readiness gate: Wait for Talos API
echo "⏳ Waiting for nodes to boot from ISO..."
for ip in 192.168.1.67 192.168.1.68 192.168.1.69; do
    echo -n "  Waiting for Talos API on $ip..."
    attempts=0
    max_attempts=60
    while ! nc -z $ip 50000 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ $attempts -eq $max_attempts ]; then
            echo " Timeout!"
            exit 1
        fi
        echo -n "."
        sleep 5
    done
    echo " ✓"
done

# Stage 2: Generate configurations
echo "📝 Stage 2: Generating Talos configurations..."
terraform apply -auto-approve \
    -target=talos_machine_secrets.this \
    -target=data.talos_machine_configuration.nodes \
    -target=data.talos_client_configuration.this \
    -target=null_resource.ensure_configs_dir \
    -target=local_file.talosconfig \
    -target=local_file.machine_configs

# Stage 3: Apply configurations to trigger installation
echo "💾 Stage 3: Applying configurations to trigger disk installation..."
export TALOSCONFIG="../talosconfig"

# Apply to all nodes to trigger installation
echo "  Applying configuration to control plane..."
talosctl apply-config --insecure -n 192.168.1.67 -f configs/talos-cp-1.yaml

echo "  Applying configuration to workers..."
talosctl apply-config --insecure -n 192.168.1.68 -f configs/talos-wk-1-gpu.yaml &
talosctl apply-config --insecure -n 192.168.1.69 -f configs/talos-wk-2.yaml &
wait

# Stage 4: Wait for installation and reboot
echo "⏳ Stage 4: Waiting for nodes to install to disk and reboot..."
echo "  This will take 2-3 minutes as nodes install and reboot..."

# First wait for nodes to start installing (they'll become unreachable)
sleep 30

# Then wait for them to come back after reboot
for ip in 192.168.1.67 192.168.1.68 192.168.1.69; do
    echo -n "  Waiting for $ip to come back after installation..."
    attempts=0
    max_attempts=120  # 10 minutes max
    while ! nc -z $ip 50000 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ $attempts -eq $max_attempts ]; then
            echo " Timeout!"
            exit 1
        fi
        echo -n "."
        sleep 5
    done
    echo " ✓"
done

# Give nodes time to stabilize
sleep 20

# Stage 5: Bootstrap the cluster
echo "🎯 Stage 5: Bootstrapping Kubernetes cluster..."

# Ensure we can connect to control plane
echo "  Verifying connection to control plane..."
until talosctl -n 192.168.1.67 version >/dev/null 2>&1; do
    echo -n "."
    sleep 5
done
echo " Connected!"

# Bootstrap
echo "  Running bootstrap command..."
talosctl bootstrap -n 192.168.1.67

# Stage 6: Wait for cluster health
echo "🔍 Stage 6: Waiting for cluster to be healthy..."
talosctl -n 192.168.1.67 health --wait-timeout=10m

# Stage 7: Get kubeconfig
echo "📥 Stage 7: Retrieving kubeconfig..."
talosctl kubeconfig -n 192.168.1.67 --force --force-context-name homelab "../kubeconfig"

# Stage 8: Verify cluster
echo "✅ Stage 8: Verifying cluster..."
export KUBECONFIG=../kubeconfig
kubectl get nodes -o wide

echo ""
echo "🎉 Deployment complete!"
echo ""
echo "Next steps:"
echo "  export KUBECONFIG=$PWD/kubeconfig"
echo "  export TALOSCONFIG=$PWD/talosconfig"
echo "  kubectl wait --for=condition=Ready nodes --all --timeout=300s"
echo "  kubectl apply -k manifests/argocd/"
echo ""
echo "To check cluster health:"
echo "  talosctl -n 192.168.1.67 health"
echo "  kubectl get nodes -o wide"