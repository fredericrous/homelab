variable "vmid" {
  description = "VM ID"
  type        = number
}

variable "name" {
  description = "VM name"
  type        = string
}

variable "target_node" {
  description = "Proxmox node"
  type        = string
}

variable "cores" {
  description = "Number of CPU cores"
  type        = number
}

variable "memory" {
  description = "Memory in MB"
  type        = number
}

variable "os_disk_size" {
  description = "OS disk size in GB"
  type        = number
}

variable "additional_disks" {
  description = "Additional disks configuration"
  type = list(object({
    size = number
  }))
  default = []
}

variable "iso_storage" {
  description = "Storage for ISO"
  type        = string
  default     = "local"
}

variable "iso_file" {
  description = "ISO filename"
  type        = string
}

variable "mac_address" {
  description = "MAC address for network interface"
  type        = string
  default     = ""
}

variable "gpu_passthrough" {
  description = "GPU PCI ID for passthrough"
  type        = string
  default     = ""
}

variable "bridge" {
  description = "Network bridge"
  type        = string
  default     = "vmbr0"
}

variable "disk_storage" {
  description = "Storage for disks"
  type        = string
  default     = "local-lvm"
}

variable "ip_address" {
  description = "Static IP address for the VM"
  type        = string
  default     = ""
}

variable "gateway" {
  description = "Network gateway"
  type        = string
  default     = ""
}

variable "dns_servers" {
  description = "DNS servers"
  type        = list(string)
  default     = []
}