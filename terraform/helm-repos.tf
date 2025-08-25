# Add all Helm repositories needed by the cluster
resource "null_resource" "helm_repos" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [local_file.kubeconfig]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      
      echo "📦 Adding Helm repositories..."
      
      # Core infrastructure
      helm repo add argo https://argoproj.github.io/argo-helm
      helm repo add cilium https://helm.cilium.io
      helm repo add cert-manager https://charts.jetstack.io
      helm repo add rook-release https://charts.rook.io/release
      helm repo add haproxytech https://haproxytech.github.io/helm-charts
      helm repo add hashicorp https://helm.releases.hashicorp.com
      helm repo add cnpg https://cloudnative-pg.github.io/charts
      helm repo add bitnami https://charts.bitnami.com/bitnami
      
      # CSI drivers
      helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
      helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
      
      # Applications
      helm repo add harbor https://helm.goharbor.io
      helm repo add nextcloud https://nextcloud.github.io/helm
      
      # Additional tools
      helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts
      helm repo add piraeus https://piraeus.io/helm-charts
      helm repo add cert-manager-webhook-ovh-charts https://aureq.github.io/cert-manager-webhook-ovh
      
      # Update all repos
      helm repo update
      
      echo "✅ Helm repositories added successfully"
      helm repo list
    EOT
  }
}