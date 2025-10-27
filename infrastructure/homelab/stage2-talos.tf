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
      TALOSCONFIG="${path.module}/../../talosconfig"

      # First check if kubectl works - that's the best indicator
      if kubectl --kubeconfig="${path.module}/../../kubeconfig" get nodes >/dev/null 2>&1; then
        echo "✅ Cluster is already bootstrapped (kubectl works)"
        exit 0
      fi

      # Brief API readiness check before bootstrap
      echo "🔍 Verifying Talos API connectivity..."
      
      for i in $(seq 1 12); do  # 2 minutes max (12 * 10s)
        if talosctl --talosconfig="$TALOSCONFIG" -n ${local.all_nodes.controlplane.ip} version >/dev/null 2>&1; then
          echo "✅ Talos API ready"
          break
        fi
        
        if [ $i -eq 12 ]; then
          echo "❌ Talos API not responding after 2 minutes"
          echo "🔧 Debug info:"
          talosctl --talosconfig="$TALOSCONFIG" -n ${local.all_nodes.controlplane.ip} version 2>&1 || true
          exit 1
        fi
        
        [ $i -eq 1 ] && echo "⏳ Waiting for API..." || echo -n "."
        sleep 10
      done

      # Try to bootstrap, but handle "already exists" error gracefully
      echo "🚀 Attempting to bootstrap Talos cluster..."
      
      # Capture both exit code and output
      bootstrap_exit_code=0
      talosctl --talosconfig="$TALOSCONFIG" bootstrap -n ${local.all_nodes.controlplane.ip} 2>&1 | tee /tmp/bootstrap.log || bootstrap_exit_code=$?
      
      if [ $bootstrap_exit_code -eq 0 ]; then
        echo "✅ Bootstrap completed successfully"
      else
        echo "⚠️  Bootstrap command exited with code: $bootstrap_exit_code"
        echo "📋 Bootstrap output:"
        cat /tmp/bootstrap.log
        
        # Check if it failed because already bootstrapped (expected errors)
        if grep -q "etcd data directory is not empty" /tmp/bootstrap.log || \
           grep -q "AlreadyExists" /tmp/bootstrap.log || \
           grep -q "already bootstrapped" /tmp/bootstrap.log; then
          echo "✅ Cluster was already bootstrapped (expected error)"
          exit 0
        # Check for certificate/TLS errors that indicate timing issues
        elif grep -q "authentication handshake failed" /tmp/bootstrap.log || \
             grep -q "certificate signed by unknown authority" /tmp/bootstrap.log || \
             grep -q "connection error" /tmp/bootstrap.log; then
          echo "⚠️  Bootstrap failed due to certificate/connectivity issues"
          echo "🔍 This usually indicates a timing issue where Talos certificates aren't ready yet"
          echo "💡 Try running 'terraform apply' again or manually run:"
          echo "   talosctl --talosconfig=./talosconfig bootstrap -n ${local.all_nodes.controlplane.ip}"
          exit 1
        else
          echo "❌ Bootstrap failed with unexpected error"
          echo "🔍 Full error details above - please investigate"
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
  count = 0 # Disabled - we use null_resource above

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
  content         = replace(talos_cluster_kubeconfig.this[0].kubeconfig_raw, "admin@${var.cluster_name}", var.cluster_name)
  filename        = "${path.module}/../../infrastructure/homelab/kubeconfig.yaml"
  file_permission = "0600"
}

resource "local_file" "talosconfig" {
  content         = data.talos_client_configuration.this.talos_config
  filename        = "${path.module}/../../talosconfig"
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
