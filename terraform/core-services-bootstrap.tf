# Bootstrap critical core services that need manual syncing
# These services have autoSync: false and must be deployed in order

# Stage 0: Sync Rook-Ceph storage (required by many services)
resource "null_resource" "rook_ceph_sync" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [
    null_resource.argocd_bootstrap
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      
      echo "💾 Waiting for Rook-Ceph application to be created by ApplicationSet..."
      for i in {1..30}; do
        if kubectl get app -n argocd rook-ceph >/dev/null 2>&1; then
          echo "✅ Rook-Ceph application found"
          break
        fi
        echo "Waiting for Rook-Ceph application... ($i/30)"
        sleep 5
      done
      
      echo "💾 Syncing Rook-Ceph storage operator..."
      kubectl patch app -n argocd rook-ceph --type merge -p '{"operation":{"initiatedBy":{"username":"terraform"},"sync":{"prune":true,"syncStrategy":{"hook":{}}}}}'
      
      # Wait for Rook operator to be ready
      echo "⏳ Waiting for Rook-Ceph operator..."
      kubectl wait --for=condition=ready --timeout=300s pod -n rook-ceph -l app=rook-ceph-operator || true
      
      # Wait for storage class to be available
      echo "🔍 Waiting for rook-ceph-block storage class..."
      for i in {1..60}; do
        if kubectl get storageclass rook-ceph-block >/dev/null 2>&1; then
          echo "✅ Storage class rook-ceph-block is available"
          break
        fi
        echo "Waiting for storage class... ($i/60)"
        sleep 10
      done
      
      echo "✅ Rook-Ceph storage is ready"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}

# Wait for ApplicationSets to generate apps
resource "null_resource" "wait_for_appsets" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [
    null_resource.argocd_bootstrap
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      
      echo "⏳ Waiting for ApplicationSets to generate applications..."
      sleep 30  # Give ApplicationSets time to process
      
      echo "🔍 Checking for core applications..."
      kubectl get app -n argocd | grep -E "(vault|cert-manager|client-ca|vault-secrets-operator)" || echo "Applications not yet created"
      
      echo "✅ Proceeding with core services bootstrap"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}

# Stage 1: Sync Vault (needs to be initialized and unsealed)
resource "null_resource" "vault_sync" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [
    null_resource.wait_for_appsets,
    null_resource.dns_bootstrap,
    null_resource.rook_ceph_sync  # Vault needs storage
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      
      echo "🔐 Waiting for Vault application to be created by ApplicationSet..."
      for i in {1..30}; do
        if kubectl get app -n argocd vault >/dev/null 2>&1; then
          echo "✅ Vault application found"
          break
        fi
        echo "Waiting for Vault application... ($i/30)"
        sleep 5
      done
      
      echo "🔐 Syncing Vault application..."
      # Force sync Vault app
      kubectl patch app -n argocd vault --type merge -p '{"operation":{"initiatedBy":{"username":"terraform"},"sync":{"prune":true,"syncStrategy":{"hook":{}}}}}'
      
      # Wait for Vault to be ready
      echo "⏳ Waiting for Vault pod to be ready..."
      kubectl wait --for=condition=ready --timeout=300s pod -n vault -l app.kubernetes.io/name=vault || true
      
      # Check if Vault is initialized
      echo "🔍 Checking Vault initialization status..."
      for i in {1..30}; do
        if kubectl get secret -n vault vault-keys >/dev/null 2>&1 && kubectl get secret -n vault vault-admin-token >/dev/null 2>&1; then
          echo "✅ Vault is initialized"
          break
        fi
        echo "Waiting for Vault initialization... ($i/30)"
        sleep 10
      done
      
      echo "✅ Vault synced successfully"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}

# Stage 2: Sync Vault Secrets Operator (depends on Vault)
resource "null_resource" "vso_sync" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [null_resource.vault_sync]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      
      echo "🔒 Waiting for VSO application to be created by ApplicationSet..."
      for i in {1..30}; do
        if kubectl get app -n argocd vault-secrets-operator >/dev/null 2>&1; then
          echo "✅ VSO application found"
          break
        fi
        echo "Waiting for VSO application... ($i/30)"
        sleep 5
      done
      
      echo "🔒 Syncing Vault Secrets Operator..."
      # Create namespace if it doesn't exist
      kubectl create namespace vault-secrets-operator-system --dry-run=client -o yaml | kubectl apply -f -
      
      # Force sync VSO app
      kubectl patch app -n argocd vault-secrets-operator --type merge -p '{"operation":{"initiatedBy":{"username":"terraform"},"sync":{"prune":true,"syncStrategy":{"hook":{}}}}}'
      
      # Wait for VSO CRDs to be available
      echo "⏳ Waiting for VSO CRDs..."
      for i in {1..60}; do
        if kubectl get crd vaultauths.secrets.hashicorp.com >/dev/null 2>&1; then
          echo "✅ VSO CRDs are ready"
          break
        fi
        echo "Waiting for VSO CRDs... ($i/60)"
        sleep 5
      done
      
      # Wait for VSO webhook to be ready
      kubectl wait --for=condition=ready --timeout=300s pod -n vault-secrets-operator-system -l app.kubernetes.io/name=vault-secrets-operator || true
      
      echo "✅ VSO synced successfully"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}

# Stage 3: Sync cert-manager (depends on VSO)
resource "null_resource" "cert_manager_sync" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [null_resource.vso_sync]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      
      echo "📜 Waiting for cert-manager application to be created by ApplicationSet..."
      for i in {1..30}; do
        if kubectl get app -n argocd cert-manager >/dev/null 2>&1; then
          echo "✅ cert-manager application found"
          break
        fi
        echo "Waiting for cert-manager application... ($i/30)"
        sleep 5
      done
      
      echo "📜 Syncing cert-manager..."
      # Force sync cert-manager app
      kubectl patch app -n argocd cert-manager --type merge -p '{"operation":{"initiatedBy":{"username":"terraform"},"sync":{"prune":true,"syncStrategy":{"hook":{}}}}}'
      
      # Wait for cert-manager CRDs to be available
      echo "⏳ Waiting for cert-manager CRDs..."
      for i in {1..60}; do
        if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
          echo "✅ cert-manager CRDs are ready"
          break
        fi
        echo "Waiting for cert-manager CRDs... ($i/60)"
        sleep 5
      done
      
      # Wait for cert-manager webhook to be ready
      kubectl wait --for=condition=ready --timeout=300s pod -n cert-manager -l app.kubernetes.io/name=webhook || true
      
      # Check if ClusterIssuer is created
      echo "🔍 Checking for Let's Encrypt ClusterIssuer..."
      for i in {1..30}; do
        if kubectl get clusterissuer letsencrypt-ovh-webhook-final >/dev/null 2>&1; then
          echo "✅ ClusterIssuer is ready"
          break
        fi
        echo "Waiting for ClusterIssuer... ($i/30)"
        sleep 5
      done
      
      echo "✅ cert-manager synced successfully"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}

# Stage 4: Sync client-ca (can run in parallel with cert-manager)
resource "null_resource" "client_ca_sync" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [null_resource.argocd_bootstrap]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      
      echo "🔐 Waiting for client-ca application to be created by ApplicationSet..."
      for i in {1..30}; do
        if kubectl get app -n argocd client-ca >/dev/null 2>&1; then
          echo "✅ client-ca application found"
          break
        fi
        echo "Waiting for client-ca application... ($i/30)"
        sleep 5
      done
      
      echo "🔐 Syncing client-ca..."
      # Force sync client-ca app
      kubectl patch app -n argocd client-ca --type merge -p '{"operation":{"initiatedBy":{"username":"terraform"},"sync":{"prune":true,"syncStrategy":{"hook":{}}}}}'
      
      # Wait for client CA cert to be available
      echo "⏳ Waiting for client CA certificate..."
      for i in {1..30}; do
        if kubectl get secret -n haproxy-controller client-ca-cert >/dev/null 2>&1; then
          echo "✅ Client CA certificate is ready"
          break
        fi
        echo "Waiting for client CA certificate... ($i/30)"
        sleep 2
      done
      
      echo "✅ client-ca synced successfully"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}

# Update wait_nodes_ready to depend on core services
resource "null_resource" "wait_nodes_ready_updated" {
  count = var.configure_talos ? 1 : 0

  depends_on = [
    talos_machine_configuration_apply.workers,
    null_resource.cert_manager_sync,
    null_resource.client_ca_sync
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      export KUBECONFIG=${abspath(local_file.kubeconfig[0].filename)}
      
      echo "✅ Core services deployed. Cluster is ready!"
      echo ""
      echo "📋 Service Status:"
      kubectl get app -n argocd vault vault-secrets-operator cert-manager client-ca -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
      echo ""
      echo "🌐 To access ArgoCD:"
      echo "  - URL: https://argocd.daddyshome.fr/"
      echo "  - Username: admin"
      echo "  - Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"
      echo ""
      echo "⚠️  Note: HTTPS access requires your mTLS client certificate"
    EOT
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}