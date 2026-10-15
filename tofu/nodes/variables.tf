# --- connection (provisioner service account) ---------------------------------
variable "vcenter_server" { type = string }
variable "vcenter_user" { type = string }
variable "vcenter_password" {
  type      = string
  sensitive = true
}
variable "allow_unverified_ssl" {
  type    = bool
  default = true
}

# --- placement -------------------------------------------------------------------
variable "datacenter" { type = string }
variable "cluster" { type = string }
variable "resource_pool" {
  description = "Resource pool name inside the cluster; empty = cluster root pool"
  type        = string
  default     = ""
}
variable "datastore" { type = string }
variable "network" { type = string }
variable "folder" {
  description = "VM folder path relative to the datacenter VM folder"
  type        = string
}
variable "template_name" { type = string }
variable "hw_version" {
  type    = number
  default = 21
}

# --- nodes -----------------------------------------------------------------------
variable "cluster_name" { type = string }
variable "control_plane_count" {
  type = number
  validation {
    condition     = var.control_plane_count >= 1 && var.control_plane_count % 2 == 1
    error_message = "control_plane_count must be an odd number >= 1 (etcd quorum)."
  }
}
variable "worker_count" {
  type    = number
  default = 0
}
variable "cp_cpus" { type = number }
variable "cp_memory_mb" { type = number }
variable "cp_disk_gb" { type = number }
variable "worker_cpus" { type = number }
variable "worker_memory_mb" { type = number }
variable "worker_disk_gb" { type = number }

variable "node_user" { type = string }
variable "ssh_public_key" { type = string }

# --- network ---------------------------------------------------------------------
variable "network_mode" {
  type    = string
  default = "dhcp"
  validation {
    condition     = contains(["dhcp", "static"], var.network_mode)
    error_message = "network_mode must be \"dhcp\" or \"static\"."
  }
}
variable "static_cidr" {
  type    = string
  default = ""
}
variable "static_ip_offset" {
  type    = number
  default = 0
}
variable "static_gateway" {
  type    = string
  default = ""
}
variable "dns_servers" {
  type    = list(string)
  default = []
}
variable "dns_search" {
  type    = list(string)
  default = []
}

# --- outputs to Ansible -----------------------------------------------------------
variable "inventory_path" {
  description = "Where to write the generated Ansible inventory"
  type        = string
}
variable "ssh_private_key_path" {
  description = "Private key Ansible uses to reach the nodes (path inside the toolbox)"
  type        = string
}
