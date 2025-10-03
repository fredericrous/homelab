# Stage 2: Talos Configuration
# This file contains Talos configuration resources
# Run: terraform apply -parallelism=10 -target=talos_machine_configuration_apply.cp -target=talos_machine_bootstrap.this
# Then: terraform apply -parallelism=10 -target=talos_machine_configuration_apply.workers -target=talos_cluster_kubeconfig.this

# Generate machine secrets (shared across all nodes)
resource "talos_machine_secrets" "this" {}

# Generate machine configurations for all nodes
data "talos_machine_configuration" "nodes" {
  for_each = local.all_nodes
  
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = each.value.machine_type
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version
  
  # All patches are applied here, not duplicated in apply resource
  config_patches = concat(
    [local.network_config[each.key]],
    local.common_patches,
    try(local.node_patches[each.key], []),
    try(local.label_patches[each.key], [])
  )
}

# Generate client configuration
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [local.all_nodes.controlplane.ip]
}

# Create configs directory once
resource "null_resource" "ensure_configs_dir" {
  provisioner "local-exec" {
    when    = create
    command = "mkdir -p ${path.module}/configs"
  }
}

# Wave 1: Apply configuration to control plane only
# Note: Initial configuration is handled by null_resource.apply_cp_config_smart
# This resource ensures configuration is maintained/updated after initial bootstrap
resource "talos_machine_configuration_apply" "cp" {
  for_each = var.configure_talos ? { for k, n in local.all_nodes : k => n if k == "controlplane" } : {}
  
  depends_on = [module.vms, null_resource.ensure_configs_dir, null_resource.apply_cp_config_smart]
  
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.nodes[each.key].machine_configuration
  node                        = each.value.ip
  endpoint                    = each.value.ip
  
  # NO config_patches here - they're already in the data source
}

# Bootstrap the cluster after control plane is configured
# Using null_resource to make it idempotent - checks if already bootstrapped
resource "null_resource" "bootstrap_cluster" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [
    talos_machine_configuration_apply.cp,
    local_file.talosconfig
  ]
  
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "🔍 Checking if cluster needs bootstrap..."
      
      # Use the talosconfig from root directory
      TALOSCONFIG="${path.module}/../talosconfig"
      
      # First check if kubectl works - that's the best indicator
      if kubectl --kubeconfig="${path.module}/../kubeconfig" get nodes >/dev/null 2>&1; then
        echo "✅ Cluster is already bootstrapped (kubectl works)"
        exit 0
      fi
      
      # Try to bootstrap, but handle "already exists" error gracefully
      echo "🚀 Attempting to bootstrap Talos cluster..."
      if talosctl --talosconfig="$TALOSCONFIG" bootstrap -n ${local.all_nodes.controlplane.ip} 2>&1 | tee /tmp/bootstrap.log; then
        echo "✅ Bootstrap completed successfully"
      else
        # Check if it failed because already bootstrapped
        if grep -q "etcd data directory is not empty" /tmp/bootstrap.log || \
           grep -q "AlreadyExists" /tmp/bootstrap.log; then
          echo "✅ Cluster was already bootstrapped"
          exit 0
        else
          echo "❌ Bootstrap failed"
          cat /tmp/bootstrap.log
          exit 1
        fi
      fi
    EOT
  }
  
  # Force replacement if the cluster changes
  triggers = {
    cluster_id = talos_machine_secrets.this.id
    endpoint   = local.all_nodes.controlplane.ip
  }
}

# Keep the original resource but only use it for importing existing state
# This prevents breaking existing deployments
resource "talos_machine_bootstrap" "this" {
  count = 0  # Disabled - we use null_resource above
  
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.all_nodes.controlplane.ip
  endpoint             = local.all_nodes.controlplane.ip
}

# Wave 2: Apply configuration to workers after bootstrap
# Note: Initial configuration is handled by null_resource.apply_worker_configs_smart
# This resource ensures configuration is maintained/updated after initial bootstrap
resource "talos_machine_configuration_apply" "workers" {
  for_each = var.configure_talos ? { for k, n in local.all_nodes : k => n if k != "controlplane" } : {}
  
  depends_on = [
    null_resource.bootstrap_cluster, 
    null_resource.apply_worker_configs_smart
  ]
  
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.nodes[each.key].machine_configuration
  node                        = each.value.ip
  endpoint                    = local.all_nodes.controlplane.ip # Use CP endpoint for better stability
  
  # NO config_patches here - they're already in the data source
}

# Get kubeconfig after bootstrap (don't wait for workers)
resource "talos_cluster_kubeconfig" "this" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [
    null_resource.bootstrap_cluster
  ]
  
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.all_nodes.controlplane.ip
  endpoint             = local.all_nodes.controlplane.ip
}

# Save configs
resource "local_file" "kubeconfig" {
  count           = var.configure_talos ? 1 : 0
  content         = talos_cluster_kubeconfig.this[0].kubeconfig_raw
  filename        = "${path.module}/../kubeconfig"
  file_permission = "0600"
}

resource "local_file" "talosconfig" {
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${path.module}/../talosconfig"
  file_permission = "0600"
}

# Save machine configs for manual application if needed
resource "local_file" "machine_configs" {
  for_each = local.all_nodes
  
  depends_on = [null_resource.ensure_configs_dir]
  
  content         = data.talos_machine_configuration.nodes[each.key].machine_configuration
  filename        = "${path.module}/configs/${each.value.hostname}.yaml"
  file_permission = "0600"
}


# Optional: Fast path using talosctl directly (comment out if you prefer pure Terraform)
# This is significantly faster but breaks pure Terraform approach
/*
resource "null_resource" "apply_configs_fast" {
  count = var.configure_talos ? 1 : 0
  depends_on = [module.vms, local_file.machine_configs, local_file.talosconfig]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      export TALOSCONFIG="${path.module}/talosconfig"
      
      # Wait for nodes to be reachable
      for ip in ${local.all_nodes.controlplane.ip} ${join(" ", [for k, n in local.all_nodes : n.ip if k != "controlplane"])}; do
        echo "Waiting for node $ip to be reachable..."
        until ping -c1 $ip >/dev/null 2>&1; do sleep 2; done
      done
      
      # Apply control plane configuration
      echo "Applying configuration to control plane..."
      talosctl apply-config --insecure -n ${local.all_nodes.controlplane.ip} -f "${path.module}/configs/${local.all_nodes.controlplane.hostname}.yaml"
      
      # Wait for API to be ready before bootstrap
      echo "Waiting for Talos API..."
      until talosctl -n ${local.all_nodes.controlplane.ip} version >/dev/null 2>&1; do sleep 5; done
      
      # Bootstrap cluster
      echo "Bootstrapping cluster..."
      talosctl bootstrap -n ${local.all_nodes.controlplane.ip}
      
      # Apply worker configurations
      %{ for k, n in local.all_nodes ~}
      %{ if k != "controlplane" ~}
      echo "Applying configuration to ${n.hostname}..."
      talosctl apply-config --insecure -n ${n.ip} -f "${path.module}/configs/${n.hostname}.yaml" &
      %{ endif ~}
      %{ endfor ~}
      wait
      
      # Fetch kubeconfig
      echo "Fetching kubeconfig..."
      talosctl kubeconfig -n ${local.all_nodes.controlplane.ip} --force --force-context homelab "${path.module}/kubeconfig"
    EOT
  }
}
*/