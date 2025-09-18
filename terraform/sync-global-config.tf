# Sync global configuration to homelab-values repository
resource "null_resource" "sync_global_config" {
  # Run early in the deployment process
  depends_on = [
    talos_machine_secrets.this
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      
      echo "🔄 Syncing global configuration to homelab-values repository..."
      
      # Check if GitHub token is set
      if [ -z "${var.github_homelab_values_token}" ]; then
        echo "⚠️  WARNING: github_homelab_values_token not set, skipping sync"
        exit 0
      fi
      
      # Check if .env file exists
      if [ ! -f "${path.module}/../.env" ]; then
        echo "⚠️  WARNING: .env file not found, skipping sync"
        exit 0
      fi
      
      # Run the sync script
      export GITHUB_HOMELAB_VALUES_TOKEN="${var.github_homelab_values_token}"
      export GITHUB_HOMELAB_VALUES_REPO="${var.github_homelab_values_repo}"
      cd ${path.module}/.. && ./scripts/sync-global-config.sh
      
      echo "✅ Global configuration synced successfully"
    EOT
  }

  # Trigger on changes to the token or cluster
  triggers = {
    github_token = var.github_homelab_values_token
    cluster_id   = talos_machine_secrets.this.id
  }
}