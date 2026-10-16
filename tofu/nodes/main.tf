locals {
  # Node map keyed by VM name so scaling a pool never renames existing nodes.
  control_plane = {
    for i in range(var.control_plane_count) : format("%s-cp-%02d", var.cluster_name, i + 1) => {
      role   = "server"
      index  = i
      cpus   = var.cp_cpus
      memory = var.cp_memory_mb
      disk   = var.cp_disk_gb
    }
  }
  workers = {
    for i in range(var.worker_count) : format("%s-wk-%02d", var.cluster_name, i + 1) => {
      role   = "agent"
      index  = var.control_plane_count + i
      cpus   = var.worker_cpus
      memory = var.worker_memory_mb
      disk   = var.worker_disk_gb
    }
  }
  nodes = merge(local.control_plane, local.workers)

  prefix_length = var.network_mode == "static" ? split("/", var.static_cidr)[1] : ""
  static_ip     = { for name, n in local.nodes : name => var.network_mode == "static" ? cidrhost(var.static_cidr, var.static_ip_offset + n.index) : "" }

  # Explicit resource pool > cluster root pool > standalone host root pool
  pool_id = (var.resource_pool != "" ? data.vsphere_resource_pool.pool[0].id :
  var.cluster != "" ? data.vsphere_compute_cluster.cluster[0].resource_pool_id : data.vsphere_host.host[0].resource_pool_id)
}

data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

data "vsphere_compute_cluster" "cluster" {
  count         = var.cluster == "" ? 0 : 1
  name          = var.cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_host" "host" {
  count         = var.host == "" ? 0 : 1
  name          = var.host
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_resource_pool" "pool" {
  count         = var.resource_pool == "" ? 0 : 1
  name          = "${var.cluster}/Resources/${var.resource_pool}"
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "ds" {
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "net" {
  name          = var.network
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "template" {
  name          = "/${var.datacenter}/vm/${var.folder}/${var.template_name}"
  datacenter_id = data.vsphere_datacenter.dc.id
}

resource "vsphere_virtual_machine" "node" {
  for_each = local.nodes

  name             = each.key
  folder           = var.folder
  resource_pool_id = local.pool_id
  host_system_id   = var.host == "" ? null : data.vsphere_host.host[0].id
  datastore_id     = data.vsphere_datastore.ds.id
  annotation       = "RKE2 ${each.value.role} of cluster ${var.cluster_name} (managed by OpenTofu)"

  num_cpus         = each.value.cpus
  memory           = each.value.memory
  guest_id         = data.vsphere_virtual_machine.template.guest_id
  firmware         = data.vsphere_virtual_machine.template.firmware
  scsi_type        = data.vsphere_virtual_machine.template.scsi_type
  hardware_version = var.hw_version
  enable_disk_uuid = true # required by vSphere CSI

  network_interface {
    network_id   = data.vsphere_network.net.id
    adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]
  }

  disk {
    label            = "disk0"
    size             = max(each.value.disk, data.vsphere_virtual_machine.template.disks[0].size)
    thin_provisioned = true
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
  }

  # cloud-init VMware datasource
  extra_config = {
    "guestinfo.metadata" = base64encode(templatefile("${path.module}/templates/metadata.yaml.tftpl", {
      hostname      = each.key
      network_mode  = var.network_mode
      address       = local.static_ip[each.key]
      prefix_length = local.prefix_length
      gateway       = var.static_gateway
      dns_servers   = var.dns_servers
      dns_search    = var.dns_search
    }))
    "guestinfo.metadata.encoding" = "base64"
    "guestinfo.userdata" = base64encode(templatefile("${path.module}/templates/userdata.yaml.tftpl", {
      hostname       = each.key
      network_mode   = var.network_mode
      node_user      = var.node_user
      ssh_public_key = trimspace(var.ssh_public_key)
    }))
    "guestinfo.userdata.encoding" = "base64"
  }

  wait_for_guest_net_timeout = 10

  lifecycle {
    # cloud-init only runs on first boot; never rebuild a node for a template refresh or user-data edit
    ignore_changes = [clone, extra_config]
  }
}

resource "local_file" "inventory" {
  filename        = var.inventory_path
  file_permission = "0644"
  content = templatefile("${path.module}/templates/inventory.yaml.tftpl", {
    servers  = { for name, n in local.nodes : name => vsphere_virtual_machine.node[name].default_ip_address if n.role == "server" }
    agents   = { for name, n in local.nodes : name => vsphere_virtual_machine.node[name].default_ip_address if n.role == "agent" }
    user     = var.node_user
    key_path = var.ssh_private_key_path
  })
}
