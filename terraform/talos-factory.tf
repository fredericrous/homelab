# Check for cached schematic IDs first
data "local_file" "schematic_base_cache" {
  count    = fileexists("${path.module}/.schematic_base_id") ? 1 : 0
  filename = "${path.module}/.schematic_base_id"
}

data "local_file" "schematic_gpu_cache" {
  count    = fileexists("${path.module}/.schematic_gpu_id") ? 1 : 0
  filename = "${path.module}/.schematic_gpu_id"
}

# Generate schematic IDs dynamically from YAML files only if not cached
data "external" "schematic_base" {
  count   = fileexists("${path.module}/.schematic_base_id") ? 0 : 1
  program = ["python3", "${path.module}/scripts/talos_factory_id.py"]

  query = {
    path = "${path.module}/schematic-base.yaml"
  }
}

data "external" "schematic_gpu" {
  count   = fileexists("${path.module}/.schematic_gpu_id") ? 0 : 1
  program = ["python3", "${path.module}/scripts/talos_factory_id.py"]

  query = {
    path = "${path.module}/schematic-gpu.yaml"
  }
}

# Cache the schematic IDs for future runs
resource "local_file" "schematic_base_cache" {
  count    = fileexists("${path.module}/.schematic_base_id") ? 0 : 1
  filename = "${path.module}/.schematic_base_id"
  content  = data.external.schematic_base[0].result.id
}

resource "local_file" "schematic_gpu_cache" {
  count    = fileexists("${path.module}/.schematic_gpu_id") ? 0 : 1
  filename = "${path.module}/.schematic_gpu_id"
  content  = data.external.schematic_gpu[0].result.id
}

locals {
  talos_version = "v1.10.6"

  # Use cached IDs if available, otherwise use dynamically generated ones
  base_schematic_id = length(data.local_file.schematic_base_cache) > 0 ? trimspace(data.local_file.schematic_base_cache[0].content) : data.external.schematic_base[0].result.id
  gpu_schematic_id  = length(data.local_file.schematic_gpu_cache) > 0 ? trimspace(data.local_file.schematic_gpu_cache[0].content) : data.external.schematic_gpu[0].result.id

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

  url                 = local.iso_url
  file_name           = local.iso_name
  overwrite           = false # Don't overwrite if it exists
  overwrite_unmanaged = true  # Take ownership of existing files

  # Ignore changes to the URL to prevent re-downloads
  lifecycle {
    ignore_changes = [url]
  }
}
