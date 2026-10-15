# vCenter privileges — maintainer notes

The role → privilege → object matrix is in **`docs/vcenter-user-profiles.md`**. It's the single human-facing
copy, so update it whenever these change:
- role contents: `roles/vcenter_bootstrap/defaults/main.yml`
- grants: `vcenter_permissions` in `roles/vcenter_bootstrap/vars/main.yml`

`playbooks/vcenter-access.yml --tags verify` reads the effective privileges back from vCenter and fails on any
gap.

## Why the non-obvious entries exist
- `VirtualMachine.Config.Rename` (provisioner): the vSphere provider sends the VM name again in the reconfigure
  it runs right after the clone. Without it you get "Permission to perform this operation was denied", and the
  provider deletes the fresh clone again.
- `VirtualMachine.Config.AdvancedConfig`: `extra_config` (guestinfo cloud-init, disk.EnableUUID).
- `VirtualMachine.Config.UpgradeVirtualHardware`: `hardware_version` in tofu.
- The separate `<cluster>-placement` role: VMs inherit permissions through resource pools, so nothing with
  VirtualMachine.* may be granted on the cluster with propagation.
- CSI role at the vCenter root, without propagation: Cns.Searchable and StorageProfile.View are checked there.

## How to find a missing privilege (instead of guessing)
- OpenTofu: run stage 2 with `-e tofu_debug=true`, then
  `grep -rhoE "<privilegeId>[^<]+</privilegeId>" .state/vsphere-debug | sort | uniq -c`.
  Delete `.state/vsphere-debug` afterwards, because it contains SOAP traces.
- In-cluster (CSI/CPI): `kubectl -n vmware-system-csi logs deploy/vsphere-csi-controller -c vsphere-csi-controller`
  shows `NoPermission` with the privilege id. The VCSA side shows it too:
  `/var/log/vmware/vpxd-svcs/vpxd-svcs.log`, lines from `AclPrivilegeValidator`.
- Add the privilege to the role list, run `playbooks/vcenter-access.yml` (or stage 1 `--tags roles`), then
  update `docs/vcenter-user-profiles.md` and the notes above.
