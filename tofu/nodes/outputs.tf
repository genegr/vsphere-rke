output "nodes" {
  description = "Node name -> { role, ip }"
  value = {
    for name, n in local.nodes : name => {
      role = n.role
      ip   = vsphere_virtual_machine.node[name].default_ip_address
    }
  }
}
