# vCenter privilege matrix

Source of truth: `roles/vcenter_bootstrap/defaults/main.yml` (role contents) and
`roles/vcenter_bootstrap/vars/main.yml` (`vcenter_permissions`, where each role is granted).
Update this file whenever either changes.

Principals are SSO users in the `vsphere.local` domain, written `VSPHERE.LOCAL\<user>`
in permissions and `<user>@vsphere.local` when logging in.

## Who gets what, where

| Principal | Role | Object | Propagate | Why |
|---|---|---|---|---|
| prov | `<cluster>-provisioner` | VM folder `<cluster>` | yes | clone/configure/power/delete node VMs; read the template |
| prov | `<cluster>-provisioner` | datastore (`vsphere_datastore`) | no | Datastore.* for the VM files |
| prov | `<cluster>-provisioner` | network (`vsphere_network`) | no | Network.Assign |
| prov | `<cluster>-placement` | cluster (or `vsphere_resource_pool`) | yes | Resource.AssignVMToPool |
| prov | ReadOnly | datacenter | no | provider looks up dc/cluster/datastore/network by name |
| csi | `<cluster>-csi` | vCenter root | no | Cns.Searchable, StorageProfile.View (CNS + SPBM queries) |
| csi | ReadOnly | datacenter | no | inventory discovery |
| csi | ReadOnly | cluster | yes | hosts and VMs for CPI node discovery |
| csi | `<cluster>-csi` | VM folder `<cluster>` | yes | attach/detach volumes on the node VMs |
| csi | `<cluster>-csi` | CSI datastore(s) | no | Datastore.FileManagement for FCD/CNS volumes |

**Never** put VirtualMachine.* privileges in a role granted on the cluster with propagation:
VMs inherit permissions through the resource-pool hierarchy too, so that would give the account
those rights on every VM in the cluster. That's why placement is a separate role.

## Role contents and the reason for each non-obvious entry

### `<cluster>-provisioner`
Datastore.AllocateSpace, Datastore.Browse, Datastore.FileManagement, Network.Assign,
VirtualMachine.Config.{AddNewDisk, AddRemoveDevice, AdvancedConfig, Annotation, CPUCount, DiskExtend,
EditDevice, Memory, Rename, Resource, Settings, UpgradeVirtualHardware},
VirtualMachine.Interact.{PowerOff, PowerOn, Reset},
VirtualMachine.Inventory.{Create, CreateFromExisting, Delete},
VirtualMachine.Provisioning.DeployTemplate

- `VirtualMachine.Config.Rename`: the vSphere provider sends the VM name again in the reconfigure
  it runs right after the clone. Without it you get "Permission to perform this operation was denied",
  and the provider deletes the fresh clone again. (Found with `-e tofu_debug=true`.)
- `VirtualMachine.Config.AdvancedConfig`: `extra_config` (guestinfo cloud-init, disk.EnableUUID).
- `VirtualMachine.Config.UpgradeVirtualHardware`: `hardware_version`.

### `<cluster>-placement`
Resource.AssignVMToPool

### `<cluster>-csi` (vSphere CSI docs, vanilla block volumes)
Cns.Searchable, StorageProfile.View, Datastore.FileManagement,
VirtualMachine.Config.{AddExistingDisk, AddRemoveDevice}

## How to find a missing privilege (instead of guessing)
- OpenTofu: run stage 2 with `-e tofu_debug=true`, then run
  `grep -rhoE "<privilegeId>[^<]+</privilegeId>" .state/vsphere-debug | sort | uniq -c`.
  Delete `.state/vsphere-debug` afterwards, because it contains SOAP traces.
- In-cluster (CSI/CPI): the controller logs show `NoPermission` with the privilege id:
  `kubectl -n vmware-system-csi logs deploy/vsphere-csi-controller -c vsphere-csi-controller`.
- Add the privilege to the role list, run `01-vcenter-bootstrap.yml --tags roles`, record it here.
