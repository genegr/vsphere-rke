#!/usr/bin/python
# -*- coding: utf-8 -*-
# Remove the vApp options (OVF ProductSection / ISO transport) that an OVA leaves on a VM.
# No upstream module can do this, and the vSphere OpenTofu provider refuses to clone a
# template whose only vApp transport is ISO unless the clone gets a client CD-ROM.
# Dropping the vApp config also leaves cloud-init's VMware (guestinfo) datasource as the
# only datasource on the clones.

DOCUMENTATION = r"""
module: vm_vapp_config
short_description: Remove the vApp configuration from a virtual machine
description:
  - Reconfigures the VM with C(vAppConfigRemoved=true) when vApp options are present.
  - The VM must not be a template (convert templates back to a VM first).
options:
  name:
    description: Name of the virtual machine.
    type: str
    required: true
  datacenter:
    description: Datacenter containing the VM (needed to disambiguate duplicate names).
    type: str
  folder:
    description: Absolute VM folder path, e.g. /DC/vm/folder (needed to disambiguate duplicate names).
    type: str
  uuid:
    description: BIOS UUID of the VM (alternative to I(name)).
    type: str
  use_instance_uuid:
    description: Treat I(uuid) as the instance UUID.
    type: bool
    default: false
  state:
    description: Only C(absent) (remove the vApp config) is supported.
    type: str
    choices: [absent]
    default: absent
extends_documentation_fragment:
  - community.vmware.vmware.documentation
"""

EXAMPLES = r"""
- name: Strip vApp options from a freshly deployed OVA
  vm_vapp_config:
    hostname: vcenter.example.com
    username: administrator@vsphere.local
    password: secret
    datacenter: DC1
    folder: /DC1/vm/k8s
    name: ubuntu-template
    state: absent
"""

RETURN = r"""
changed:
  description: Whether the vApp configuration was removed.
  type: bool
  returned: always
"""

try:
    from pyVmomi import vim
except ImportError:
    pass

from ansible.module_utils.basic import AnsibleModule
from ansible_collections.community.vmware.plugins.module_utils.vmware import (
    PyVmomi,
    vmware_argument_spec,
    wait_for_task,
)


def main():
    argument_spec = vmware_argument_spec()
    argument_spec.update(
        name=dict(type="str"),
        uuid=dict(type="str"),
        use_instance_uuid=dict(type="bool", default=False),
        datacenter=dict(type="str"),
        folder=dict(type="str"),
        state=dict(type="str", choices=["absent"], default="absent"),
    )
    module = AnsibleModule(
        argument_spec=argument_spec,
        required_one_of=[["name", "uuid"]],
        supports_check_mode=True,
    )

    pyv = PyVmomi(module)
    vm = pyv.get_vm()
    if vm is None:
        module.fail_json(msg="VM %s not found" % (module.params["name"] or module.params["uuid"]))
    if vm.config.template:
        module.fail_json(msg="VM %s is a template; convert it to a VM first" % vm.name)

    if vm.config.vAppConfig is None:
        module.exit_json(changed=False)

    if not module.check_mode:
        task = vm.ReconfigVM_Task(spec=vim.vm.ConfigSpec(vAppConfigRemoved=True))
        try:
            wait_for_task(task)
        except Exception as exc:  # task errors surface as generic exceptions
            module.fail_json(msg="Failed to remove vApp config from %s: %s" % (vm.name, exc))
    module.exit_json(changed=True)


if __name__ == "__main__":
    main()
