# Add essential Helm repositories needed for initial cluster setup
# Other repositories will be managed by Flux HelmRepository resources
resource "null_resource" "helm_repos" {
  count = var.configure_talos ? 1 : 0

  depends_on = [
    local_file.kubeconfig
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}

      echo "📦 Adding essential Helm repositories..."

      # Only add repos needed for initial cluster bootstrap
      helm repo add cilium https://helm.cilium.io || true
      helm repo add coredns https://coredns.github.io/helm || true
      helm repo add fluxcd-community https://fluxcd-community.github.io/helm-charts || true

      # Update repos
      helm repo update

      echo "✅ Essential Helm repositories added successfully"
      helm repo list
    EOT
  }
}
