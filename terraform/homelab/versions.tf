terraform {
  required_version = ">= 1.8.0"
  
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.78.1"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.8.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    deepmerge = {
      source  = "isometry/deepmerge"
      version = "1.1.0"
    }
  }
}