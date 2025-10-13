# Provider configuration
provider "proxmox" {
  endpoint = var.proxmox_api_url
  username = var.proxmox_user
  password = var.proxmox_password
  insecure = var.proxmox_tls_insecure
}

provider "talos" {}

provider "deepmerge" {}

