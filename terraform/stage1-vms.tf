# Stage 1: VM Creation Only
# This file contains only VM creation resources
# Run: terraform apply -parallelism=1 -target=module.vms -target=null_resource.wait_talos_ready

module "vms" {
  for_each = local.all_nodes
  source   = "./modules/vm"

  vmid            = each.value.vmid
  name            = each.value.hostname
  target_node     = var.proxmox_node
  cores           = each.value.cores
  memory          = each.value.memory
  os_disk_size    = each.value.os_disk_size
  # Use the same standard ISO for all nodes (extensions are installed via install.image)
  iso_file        = proxmox_virtual_environment_download_file.talos_iso.id
  mac_address     = each.value.mac_address != "" ? each.value.mac_address : ""
  gpu_passthrough = try(each.value.gpu_passthrough, "")
  additional_disks = try(each.value.data_disk_size, null) != null ? [{
    size = each.value.data_disk_size
  }] : []
  
  # Network configuration
  ip_address   = each.value.ip
  gateway      = var.gateway
  dns_servers  = var.dns_servers
}

# Readiness check - wait for Talos API to be available on all nodes
resource "null_resource" "wait_talos_ready" {
  for_each = local.all_nodes
  
  depends_on = [module.vms]
  
  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for Talos API on ${each.value.hostname} (${each.value.ip})..."
      attempts=0
      max_attempts=60
      while ! nc -z ${each.value.ip} 50000 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ $attempts -eq $max_attempts ]; then
          echo "Timeout waiting for Talos API on ${each.value.ip}"
          exit 1
        fi
        echo -n "."
        sleep 5
      done
      echo " Ready!"
    EOT
  }
}

