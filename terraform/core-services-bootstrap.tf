# Bootstrap critical core services that need manual syncing
# These services have autoSync: false and must be deployed in order

# Stage 0: Sync Rook-Ceph storage (required by many services)
resource "null_resource" "rook_ceph_sync" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [
    null_resource.argocd_bootstrap
  ]

  provisioner "local-exec" {
    command = "${path.module}/scripts/sync-rook-ceph.sh '${abspath(local_file.kubeconfig[0].filename)}'"
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
    command = "${path.module}/scripts/wait-for-appsets.sh '${abspath(local_file.kubeconfig[0].filename)}'"
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
    command = "${path.module}/scripts/vault-sync-enhanced.sh '${abspath(local_file.kubeconfig[0].filename)}'"
    environment = {
      K8S_VAULT_TRANSIT_TOKEN = var.k8s_vault_transit_token
    }
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}

# Stage 2: Sync External Secrets Operator (depends on Vault)
resource "null_resource" "eso_sync" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [null_resource.vault_sync]

  provisioner "local-exec" {
    command = "${path.module}/scripts/sync-external-secrets.sh '${abspath(local_file.kubeconfig[0].filename)}'"
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}

# Stage 2b: Sync Stakater Reloader (for auto-reloading on secret changes)
resource "null_resource" "reloader_sync" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [null_resource.eso_sync]

  provisioner "local-exec" {
    command = "${path.module}/scripts/sync-reloader.sh '${abspath(local_file.kubeconfig[0].filename)}'"
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}

# Stage 3: Sync cert-manager (depends on ESO)
resource "null_resource" "cert_manager_sync" {
  count = var.configure_talos ? 1 : 0
  
  depends_on = [null_resource.reloader_sync]

  provisioner "local-exec" {
    command = "${path.module}/scripts/sync-cert-manager.sh '${abspath(local_file.kubeconfig[0].filename)}'"
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
    null_resource.cert_manager_sync
  ]

  provisioner "local-exec" {
    command = "${path.module}/scripts/show-cluster-status.sh '${abspath(local_file.kubeconfig[0].filename)}'"
  }

  triggers = {
    cluster_id = talos_machine_secrets.this.id
  }
}