# Deploy ArgoCD with local-exec due to kubeconfig limitations
resource "null_resource" "argocd_install" {
  count = var.configure_talos ? 1 : 0

  depends_on = [
    local_file.kubeconfig,
    null_resource.helm_repos,
    null_resource.dns_bootstrap
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      
      echo "🔍 Checking if ArgoCD is already installed..."
      if kubectl get deployment -n argocd argocd-server >/dev/null 2>&1; then
        echo "✅ ArgoCD already installed, skipping"
        exit 0
      fi
      
      echo "🚀 Installing ArgoCD..."
      helm install argocd argo/argo-cd \
        --version 7.7.12 \
        --namespace argocd \
        --create-namespace \
        --wait --timeout 10m \
        --set server.extraArgs[0]="--insecure" \
        --set redis.enabled=true \
        --set server.resources.limits.cpu=500m \
        --set server.resources.limits.memory=512Mi \
        --set server.resources.requests.cpu=250m \
        --set server.resources.requests.memory=256Mi \
        --set controller.resources.limits.cpu=1000m \
        --set controller.resources.limits.memory=1Gi \
        --set controller.resources.requests.cpu=500m \
        --set controller.resources.requests.memory=512Mi \
        --set repoServer.resources.limits.cpu=500m \
        --set repoServer.resources.limits.memory=512Mi \
        --set repoServer.resources.requests.cpu=250m \
        --set repoServer.resources.requests.memory=256Mi \
        --set dex.enabled=false \
        --set applicationSet.enabled=true \
        --set applicationSet.resources.limits.cpu=500m \
        --set applicationSet.resources.limits.memory=512Mi \
        --set applicationSet.resources.requests.cpu=250m \
        --set applicationSet.resources.requests.memory=256Mi
      
      echo "✅ ArgoCD installed successfully"
    EOT
  }

  # Trigger replacement if cluster is recreated
  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}

# Bootstrap ArgoCD with app-of-apps
resource "null_resource" "argocd_bootstrap" {
  count = var.configure_talos ? 1 : 0

  depends_on = [null_resource.argocd_install]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      
      echo "⏳ Waiting for ArgoCD to be ready..."
      kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd || true
      
      echo "🚀 Bootstrapping ArgoCD with app-of-apps..."
      # Apply kustomize, but delete any existing jobs that might conflict
      kubectl delete job argocd-redis-secret-init -n argocd --ignore-not-found=true
      
      # Use kustomize with --enable-helm flag to process Helm charts
      kustomize build ${path.module}/../manifests/argocd --enable-helm | kubectl apply -f -
      
      # If kustomize fails, check what happened but don't fail the deployment
      if [ $? -ne 0 ]; then
        echo "⚠️  Some ArgoCD resources may have failed to apply (this is normal for CRDs)"
        echo "ArgoCD will reconcile these once it's running"
      fi
      
      echo "✅ ArgoCD bootstrap initiated - it will manage all applications including Cilium"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}

# Get ArgoCD admin password after deployment
resource "null_resource" "argocd_info" {
  count = var.configure_talos ? 1 : 0

  depends_on = [null_resource.argocd_install, null_resource.argocd_bootstrap]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail

      export KUBECONFIG=${abspath("${path.module}/../kubeconfig")}

      echo ""
      echo "📝 ArgoCD initial admin password:"
      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d || echo "Secret not found"
      echo ""
      echo ""
      echo "🌐 Access ArgoCD:"
      echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
      echo "  Then visit: https://localhost:8080"
      echo "  Username: admin"
    EOT
  }
}
