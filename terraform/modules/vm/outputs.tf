output "vmid" {
  description = "VM ID"
  value       = proxmox_virtual_environment_vm.vm.vm_id
}

output "name" {
  description = "VM name"
  value       = proxmox_virtual_environment_vm.vm.name
}

output "ip_address" {
  description = "VM IP address"
  value       = try(proxmox_virtual_environment_vm.vm.ipv4_addresses[0][0], "")
}

output "cloud_init_password" {
  value       = random_password.vm_password.result
  sensitive   = true
  description = "Cloud-init password (not used by Talos, only for Proxmox requirement)"
}