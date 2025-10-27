# Dynamic VM outputs
output "vm_ids" {
  description = "VM IDs for all nodes"
  value = {
    for k, v in module.vms : k => v.vmid
  }
}

output "vm_info" {
  description = "Summary of created VMs"
  value = {
    for k, v in local.all_nodes : k => {
      id          = module.vms[k].vmid
      name        = module.vms[k].name
      cores       = v.cores
      memory      = v.memory
      ip          = v.ip
      mac_address = v.mac_address
      disk        = v.os_disk_size
      data_disk   = try(v.data_disk_size, null)
    }
  }
}

output "talos_config_files" {
  description = "Generated configuration files"
  value = {
    kubeconfig  = "${path.module}/../../kubeconfig"
    talosconfig = "${path.module}/../../talosconfig"
  }
}

output "cluster_info" {
  description = "Kubernetes cluster information"
  value = {
    name     = var.cluster_name
    endpoint = var.cluster_endpoint
  }
}

output "talos_client_configuration" {
  description = "Talos client configuration"
  value = {
    nodes     = [for k, v in local.all_nodes : v.ip]
    endpoints = [local.all_nodes.controlplane.ip]
  }
}

output "next_steps" {
  description = "Next steps after deployment"
  value       = <<-EOT
    Cluster deployed! Next steps:

    1. Set up kubectl:
       export KUBECONFIG=${path.module}/kubeconfig.yaml
       kubectl get nodes

    2. Set up talosctl:
       export TALOSCONFIG=${path.module}/../talosconfig
       talosctl get members

  EOT
}
