# Generate schematic IDs dynamically from YAML files
data "external" "schematic_base" {
  program = ["python3", "${path.module}/../scripts/talos_factory_id.py"]
  
  query = {
    path = "${path.module}/schematic-base.yaml"
  }
}

data "external" "schematic_gpu" {
  program = ["python3", "${path.module}/../scripts/talos_factory_id.py"]
  
  query = {
    path = "${path.module}/schematic-gpu.yaml"
  }
}

locals {
  talos_version = "v1.10.6"

  # Use dynamically generated schematic IDs
  base_schematic_id = data.external.schematic_base.result.id
  gpu_schematic_id  = data.external.schematic_gpu.result.id
  
  # Use base schematic for ISO boot (all nodes boot from same ISO)
  # Actual extensions are installed via install.image
  iso_name = "talos-${local.talos_version}-nocloud-amd64.iso"
  iso_url  = "https://factory.talos.dev/image/${local.base_schematic_id}/${local.talos_version}/nocloud-amd64.iso"
}

# Download the standard Talos ISO for all nodes
resource "proxmox_virtual_environment_download_file" "talos_iso" {
  node_name    = var.proxmox_node
  datastore_id = var.proxmox_iso_storage
  content_type = "iso"

  url                   = local.iso_url
  file_name             = local.iso_name
  overwrite             = true
  overwrite_unmanaged   = true
}