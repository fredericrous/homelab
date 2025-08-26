# Add all Helm repositories needed by the cluster
resource "null_resource" "helm_repos" {
  count = var.configure_talos ? 1 : 0

  depends_on = [
    local_file.kubeconfig
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}

      echo "📦 Adding Helm repositories..."

      # Core infrastructure
      helm repo add argo https://argoproj.github.io/argo-helm || true
      helm repo add cilium https://helm.cilium.io || true
      helm repo add cert-manager https://charts.jetstack.io || true
      helm repo add rook-release https://charts.rook.io/release || true
      helm repo add haproxytech https://haproxytech.github.io/helm-charts || true
      helm repo add hashicorp https://helm.releases.hashicorp.com || true
      helm repo add cnpg https://cloudnative-pg.github.io/charts || true
      helm repo add bitnami https://charts.bitnami.com/bitnami || true

      # CSI drivers
      helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts || true
      helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts || true

      # Applications
      helm repo add harbor https://helm.goharbor.io || true
      # Skip nextcloud - already exists with different URL
      helm repo add nextcloud https://nextcloud.github.io/helm || true

      # Additional tools
      helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts || true
      helm repo add piraeus https://piraeus.io/helm-charts || true
      helm repo add cert-manager-webhook-ovh-charts https://aureq.github.io/cert-manager-webhook-ovh || true

      # Update all repos
      helm repo update

      echo "✅ Helm repositories added successfully"
      helm repo list
    EOT
  }
}
