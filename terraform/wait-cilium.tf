# Wait until Cilium is rolled out (so the cluster has CNI)
resource "null_resource" "wait_for_cilium" {
  count = var.configure_talos ? 1 : 0
  depends_on = [local_file.kubeconfig]

  provisioner "local-exec" {
    command = <<EOT
set -euo pipefail
export KUBECONFIG=${path.module}/../kubeconfig
echo "Waiting for Cilium to be ready..."
# namespace and name are stable for Cilium
kubectl -n kube-system wait --for=condition=available deployment/cilium-operator --timeout=10m || true
kubectl -n kube-system rollout status ds/cilium --timeout=10m
echo "Cilium is ready!"
EOT
  }
}