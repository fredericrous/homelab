# Proxmox connection
variable "proxmox_api_url" {
  description = "Proxmox API URL"
  type        = string
  default     = "https://192.168.1.1:8006/api2/json"

  validation {
    condition     = can(regex("^https?://", var.proxmox_api_url))
    error_message = "Proxmox API URL must start with http:// or https://"
  }
}

variable "proxmox_user" {
  description = "Proxmox user"
  type        = string
  default     = "root@pam"
}

variable "proxmox_password" {
  description = "Proxmox password"
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  description = "Proxmox node name"
  type        = string
  default     = "pve"
}

variable "proxmox_iso_storage" {
  description = "Proxmox storage for ISOs"
  type        = string
  default     = "local"
}

variable "proxmox_tls_insecure" {
  description = "Allow insecure TLS for Proxmox"
  type        = bool
  default     = true
}

# Network configuration
variable "gateway" {
  description = "Network gateway"
  type        = string
  default     = "192.168.1.1"
}

variable "dns_servers" {
  description = "DNS servers"
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

# Cluster configuration
variable "cluster_name" {
  description = "Kubernetes cluster name"
  type        = string
  default     = "homelab"
}

variable "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  type        = string
  default     = "https://192.168.1.67:6443"

  validation {
    condition     = can(regex("^https://.*:6443$", var.cluster_endpoint))
    error_message = "Cluster endpoint must be in format https://IP:6443"
  }
}

# Node configuration
variable "nodes" {
  description = "Node configurations - values will be merged with defaults in locals.tf"
  type = object({
    controlplane = object({
      name         = optional(string, "talos-cp-1")
      vmid         = optional(number, 100)
      ip           = string
      mac_address  = optional(string, "")
      cores        = optional(number)
      memory       = optional(number)
      os_disk_size = optional(number)
      labels       = optional(map(string), {})
    })
    workers = list(object({
      name            = string
      vmid            = number
      ip              = string
      mac_address     = optional(string, "")
      cores           = optional(number)
      memory          = optional(number)
      os_disk_size    = optional(number)
      data_disk_size  = optional(number)
      gpu_passthrough = optional(string)
      labels          = optional(map(string), {})
    }))
  })

  default = {
    controlplane = {
      ip          = "192.168.1.67"
      mac_address = ""
      labels      = {}
    }
    workers = [
      {
        name            = "talos-wk-1-gpu"
        vmid            = 101
        ip              = "192.168.1.68"
        mac_address     = ""
        cores           = 12
        memory          = 48128
        os_disk_size    = 128
        data_disk_size  = 800
        gpu_passthrough = "0000:01:00"
        labels          = {}
      },
      {
        name            = "talos-wk-2"
        vmid            = 102
        ip              = "192.168.1.69"
        mac_address     = ""
        cores           = 10
        memory          = 37888
        os_disk_size    = 96
        data_disk_size  = 673
        gpu_passthrough = null
        labels          = {}
      }
    ]
  }

  validation {
    condition = alltrue([
      for worker in var.nodes.workers : worker.vmid > 100 && worker.vmid < 1000
    ])
    error_message = "Worker VM IDs must be between 101 and 999"
  }
}

# Talos configuration
variable "talos_version" {
  description = "Talos version"
  type        = string
  default     = "v1.10.6"

  validation {
    condition     = can(regex("^v\\d+\\.\\d+\\.\\d+$", var.talos_version))
    error_message = "Talos version must be in format vX.Y.Z"
  }
}

variable "kubernetes_version" {
  description = "Kubernetes version"
  type        = string
  default     = "v1.33.3"

  validation {
    condition     = can(regex("^v\\d+\\.\\d+\\.\\d+$", var.kubernetes_version))
    error_message = "Kubernetes version must be in format vX.Y.Z"
  }
}

variable "configure_talos" {
  description = "Whether to apply Talos configuration (set to true after VMs have static IPs)"
  type        = bool
  default     = false
}


variable "talos_install_image_base" {
  description = "Talos installation image for base nodes (can be overridden, defaults to dynamically generated)"
  type        = string
  default     = ""
}

variable "talos_install_image_gpu" {
  description = "Talos installation image for GPU nodes (can be overridden, defaults to dynamically generated)"
  type        = string
  default     = ""
}

# ISO configuration
variable "iso_storage" {
  description = "Proxmox storage for ISOs"
  type        = string
  default     = "local"
}

variable "talos_iso" {
  description = "Talos ISO filename"
  type        = string
  default     = "talos-nocloud-amd64.iso"
}

variable "talos_install_disk" {
  description = "Target disk device for Talos install (/dev/sda for SCSI, /dev/vda for VirtIO)"
  type        = string
  default     = "/dev/sda" # set to /dev/vda if your VM OS disk is VirtIO
}

variable "talos_install_wipe" {
  description = "Wipe disk before install (set true for first install; set false afterwards)"
  type        = bool
  default     = true
}

# Vault configuration
variable "k8s_vault_transit_token" {
  description = "Vault transit token for auto-unseal (can be set via K8S_VAULT_TRANSIT_TOKEN or TF_VAR_k8s_vault_transit_token env var)"
  type        = string
  default     = ""
  sensitive   = true
}

