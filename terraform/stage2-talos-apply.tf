# Stage 2: Talos Configuration Apply with insecure fallback
# This handles the initial configuration of nodes that might be in maintenance mode

# Apply configuration with insecure fallback for control plane
resource "null_resource" "apply_cp_config_smart" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [
    module.vms, 
    null_resource.ensure_configs_dir, 
    local_file.machine_configs,
    local_file.talosconfig,
    null_resource.wait_talos_ready
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      export TALOSCONFIG="${abspath(local_file.talosconfig.filename)}"
      
      echo "🔍 Checking control plane configuration status..."
      
      # Try to connect with normal (secure) mode first
      if talosctl -n ${local.all_nodes.controlplane.ip} version >/dev/null 2>&1; then
        echo "✅ Control plane already configured, skipping..."
      else
        echo "📝 Applying initial configuration to control plane (insecure mode)..."
        talosctl apply-config --insecure -n ${local.all_nodes.controlplane.ip} \
          -f "${abspath(local_file.machine_configs["controlplane"].filename)}"
        
        echo "⏳ Waiting for Talos API to become secure..."
        attempts=0
        while ! talosctl -n ${local.all_nodes.controlplane.ip} version >/dev/null 2>&1; do
          attempts=$((attempts + 1))
          if [ $attempts -gt 60 ]; then
            echo "❌ Timeout waiting for secure API"
            exit 1
          fi
          echo -n "."
          sleep 5
        done
        echo " Ready!"
      fi
    EOT
  }
  
  triggers = {
    machine_config = data.talos_machine_configuration.nodes["controlplane"].machine_configuration
  }
}

# Apply configuration with insecure fallback for workers
resource "null_resource" "apply_worker_configs_smart" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [
    null_resource.bootstrap_cluster, 
    local_file.machine_configs,
    local_file.talosconfig,
    null_resource.wait_talos_ready
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      export TALOSCONFIG="${abspath(local_file.talosconfig.filename)}"
      
      # Function to apply config with smart fallback
      apply_worker_config() {
        local node_ip=$1
        local node_name=$2
        local config_file=$3
        
        echo "🔍 Checking $node_name configuration status..."
        
        # Try to connect with normal (secure) mode first
        if talosctl -n $node_ip version >/dev/null 2>&1; then
          echo "✅ $node_name already configured, skipping..."
        else
          echo "📝 Applying initial configuration to $node_name (insecure mode)..."
          talosctl apply-config --insecure -n $node_ip -f "$config_file"
          
          echo "⏳ Waiting for $node_name API to become secure..."
          attempts=0
          while ! talosctl -n $node_ip version >/dev/null 2>&1; do
            attempts=$((attempts + 1))
            if [ $attempts -gt 60 ]; then
              echo "❌ Timeout waiting for secure API on $node_name"
              return 1
            fi
            echo -n "."
            sleep 5
          done
          echo " Ready!"
        fi
      }
      
      # Apply to all workers in parallel
      %{ for k, n in local.all_nodes ~}
      %{ if k != "controlplane" ~}
      apply_worker_config "${n.ip}" "${n.hostname}" "${abspath(local_file.machine_configs[k].filename)}" &
      %{ endif ~}
      %{ endfor ~}
      
      # Wait for all background jobs
      wait
      echo "✅ All worker configurations applied"
    EOT
  }
  
  triggers = {
    for k, n in local.all_nodes : 
    "${k}_config" => data.talos_machine_configuration.nodes[k].machine_configuration
    if k != "controlplane"
  }
}

# Use the native talos_machine_bootstrap after control plane is configured
# (This replaces the insecure config with secure connection)