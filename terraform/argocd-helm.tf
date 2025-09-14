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
      if helm list -n argocd | grep -q "^argocd"; then
        echo "✅ ArgoCD Helm release already exists"
        # Check if it's in a failed state
        if helm status argocd -n argocd | grep -q "STATUS: failed"; then
          echo "⚠️  ArgoCD is in failed state, upgrading..."
          
          # Load environment variables
          if [ -f "${path.module}/../.env" ]; then
            set -a
            source "${path.module}/../.env"
            set +a
          fi
          
          # Create temporary values files with substituted variables
          TEMP_VALUES_BASE=$(mktemp)
          TEMP_VALUES_SUBSTITUTED=$(mktemp)
          cp ${path.module}/argocd-values.yaml "$TEMP_VALUES_BASE"
          cat ${path.module}/../manifests/argocd/values.yaml | envsubst '$ARGO_EXTERNAL_DOMAIN' > "$TEMP_VALUES_SUBSTITUTED"
          
          helm upgrade argocd argo/argo-cd \
            --version 7.7.12 \
            --namespace argocd \
            --create-namespace \
            --wait --timeout 10m \
            --values "$TEMP_VALUES_BASE" \
            --values "$TEMP_VALUES_SUBSTITUTED"
          
          rm -f "$TEMP_VALUES_BASE" "$TEMP_VALUES_SUBSTITUTED"
        else
          echo "✅ ArgoCD is already deployed and healthy"
        fi
        exit 0
      fi
      
      # Load environment variables
      if [ -f "${path.module}/../.env" ]; then
        set -a
        source "${path.module}/../.env"
        set +a
      fi
      
      # Create temporary values files with substituted variables
      echo "Creating temporary values files..."
      TEMP_VALUES_BASE=$(mktemp)
      TEMP_VALUES_SUBSTITUTED=$(mktemp)
      cp ${path.module}/argocd-values.yaml "$TEMP_VALUES_BASE"
      cat ${path.module}/../manifests/argocd/values.yaml | envsubst '$ARGO_EXTERNAL_DOMAIN' > "$TEMP_VALUES_SUBSTITUTED"
      
      echo "🚀 Installing ArgoCD..."
      helm install argocd argo/argo-cd \
        --version 7.7.12 \
        --namespace argocd \
        --create-namespace \
        --wait --timeout 10m \
        --values "$TEMP_VALUES_BASE" \
        --values "$TEMP_VALUES_SUBSTITUTED"
      
      # Clean up temp files
      rm -f "$TEMP_VALUES_BASE" "$TEMP_VALUES_SUBSTITUTED"
      
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
      
      # Load environment variables from .env file
      if [ -f "${path.module}/../.env" ]; then
        echo "Loading environment variables..."
        set -a
        source "${path.module}/../.env"
        set +a
      fi
      
      # Verify the external domain is loaded
      if [ -z "$ARGO_EXTERNAL_DOMAIN" ]; then
        echo "ERROR: ARGO_EXTERNAL_DOMAIN not set!"
        exit 1
      fi
      echo "Using external domain: $ARGO_EXTERNAL_DOMAIN"
      
      # Use kustomize with --enable-helm flag to process Helm charts and substitute variables
      kustomize build ${path.module}/../manifests/argocd --enable-helm | envsubst '$ARGO_EXTERNAL_DOMAIN' | kubectl apply -f -
      
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
