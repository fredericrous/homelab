#!/bin/bash
# Deterministic two-stage deployment script for Talos cluster
# Stage 1: Create VMs with parallelism control
# Stage 2: Configure Talos in waves

set -euo pipefail

echo "🚀 Starting deterministic Talos deployment..."

# Change to terraform directory
cd terraform

# Initialize Terraform if needed
if [ ! -d ".terraform" ]; then
    echo "🔧 Initializing Terraform..."
    terraform init
fi

# Check if VMs already exist (only if state file exists)
if [ -f "terraform.tfstate" ] && terraform state list 2>/dev/null | grep -q "module.vms"; then
    echo "⚠️  VMs already exist in state. Run 'terraform destroy' first if you want a clean deployment."
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Stage 1: Create VMs and wait for readiness
echo "📦 Stage 1: Creating VMs and waiting for Talos API..."
echo "  Using parallelism=1 to avoid Proxmox provider conflicts"
terraform apply -auto-approve -parallelism=1 \
    -target=data.external.schematic_base \
    -target=data.external.schematic_gpu \
    -target=proxmox_virtual_environment_download_file.talos_iso \
    -target=module.vms \
    -target=null_resource.wait_talos_ready

# Stage 2a: Generate configurations and apply to control plane
echo "🎯 Stage 2a: Configuring control plane and bootstrapping..."
terraform apply -auto-approve -parallelism=10 \
    -var="configure_talos=true" \
    -target=data.external.schematic_base \
    -target=data.external.schematic_gpu \
    -target=talos_machine_secrets.this \
    -target=data.talos_machine_configuration.nodes \
    -target=data.talos_client_configuration.this \
    -target=null_resource.ensure_configs_dir \
    -target=local_file.talosconfig \
    -target=local_file.machine_configs \
    -target=talos_machine_configuration_apply.cp \
    -target=talos_machine_bootstrap.this

# Stage 2b: Configure workers and get kubeconfig
echo "👷 Stage 2b: Configuring workers..."
terraform apply -auto-approve -parallelism=10 \
    -var="configure_talos=true" \
    -target=talos_machine_configuration_apply.workers \
    -target=talos_cluster_kubeconfig.this \
    -target=local_file.kubeconfig

# Stage 3: Install Cilium with Helm provider
echo "🚀 Stage 3: Installing Cilium CNI with Helm provider..."
terraform apply -auto-approve -target=helm_release.cilium

# Stage 4: Wait for nodes to be ready
echo "⏳ Stage 4: Waiting for nodes to be Ready..."
terraform apply -auto-approve -target=null_resource.wait_nodes_ready

# Stage 5: Add Helm repositories
echo "📦 Stage 5: Adding Helm repositories..."
terraform apply -auto-approve -target=null_resource.helm_repos

# Stage 6: Deploy ArgoCD
echo "🚀 Stage 6: Deploying ArgoCD..."
terraform apply -auto-approve -target=helm_release.argocd -target=null_resource.argocd_info

echo "✅ Stage 7: Verifying cluster..."
export KUBECONFIG=../kubeconfig
kubectl get nodes
echo ""
kubectl get pods -n argocd

echo "🎉 Deployment complete!"
echo ""
echo "Next steps:"
echo "  export KUBECONFIG=$PWD/kubeconfig"
echo "  export TALOSCONFIG=$PWD/talosconfig"
echo "  kubectl apply -k ../manifests/apps/  # Deploy applications via ArgoCD"
echo ""
echo "To check cluster health:"
echo "  talosctl -n 192.168.1.67 health"