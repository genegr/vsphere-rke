# vCenter user profiles (minimum privileges)

This project uses two dedicated vCenter SSO users. Neither has administrator rights. The SSO administrator is
only needed once, to create them (`playbooks/vcenter-access.yml`, or stage 1 of `site.yml`).

| User | Used by | Purpose |
|---|---|---|
| `svc-<cluster>-prov` | OpenTofu (stage 2) | create, configure, power and delete the node VMs |
| `svc-<cluster>-csi` | vSphere CSI driver and CPI, in-cluster | create/attach/expand/delete volumes, discover nodes |

Verified on vCenter 8.0.3 with vSphere provider 2.17.1, vSphere CSI v3.7.4 and CPI 1.36: VM create/destroy,
plus volume create, attach, online expand, move between nodes and delete.

## Roles

**`<cluster>-provisioner`** (23 privileges)

| Privilege ID | vSphere Client name |
|---|---|
| Datastore.AllocateSpace | Datastore › Allocate space |
| Datastore.Browse | Datastore › Browse datastore |
| Datastore.FileManagement | Datastore › Low level file operations |
| Network.Assign | Network › Assign network |
| VirtualMachine.Config.AddNewDisk | Virtual machine › Change Configuration › Add new disk |
| VirtualMachine.Config.AddRemoveDevice | … › Add or remove device |
| VirtualMachine.Config.AdvancedConfig | … › Advanced configuration (cloud-init guestinfo, disk.EnableUUID) |
| VirtualMachine.Config.Annotation | … › Set annotation |
| VirtualMachine.Config.CPUCount | … › Change CPU count |
| VirtualMachine.Config.DiskExtend | … › Extend virtual disk |
| VirtualMachine.Config.EditDevice | … › Modify device settings |
| VirtualMachine.Config.Memory | … › Change memory |
| VirtualMachine.Config.Rename | … › Rename (the provider re-sends the name after cloning) |
| VirtualMachine.Config.Resource | … › Change resource |
| VirtualMachine.Config.Settings | … › Change settings |
| VirtualMachine.Config.UpgradeVirtualHardware | … › Upgrade virtual machine compatibility |
| VirtualMachine.Interact.PowerOn / PowerOff / Reset | Virtual machine › Interaction › Power on / Power off / Reset |
| VirtualMachine.Inventory.Create / CreateFromExisting / Delete | Virtual machine › Edit inventory › Create new / Create from existing / Remove |
| VirtualMachine.Provisioning.DeployTemplate | Virtual machine › Provisioning › Deploy template |

**`<cluster>-placement`**: Resource.AssignVMToPool (Resource › Assign virtual machine to resource pool)

**`<cluster>-csi`** (5 privileges)

| Privilege ID | vSphere Client name |
|---|---|
| Cns.Searchable | Cloud Native Storage › Searchable |
| StorageProfile.View | VM storage policies › View VM storage policies |
| Datastore.FileManagement | Datastore › Low level file operations |
| VirtualMachine.Config.AddExistingDisk | Virtual machine › Change Configuration › Add existing disk |
| VirtualMachine.Config.AddRemoveDevice | … › Add or remove device |

**Read-only** is the built-in role.

## Where each role is granted

| User | Role | Object | Propagate |
|---|---|---|---|
| prov | `<cluster>-provisioner` | VM folder `<cluster>` (holds the template and the nodes) | yes |
| prov | `<cluster>-provisioner` | node datastore (`vsphere_datastore`) | no |
| prov | `<cluster>-provisioner` | node network (`vsphere_network`) | no |
| prov | `<cluster>-placement` | compute cluster (or `vsphere_resource_pool`) | yes |
| prov | Read-only | datacenter | no |
| csi | `<cluster>-csi` | vCenter root | no |
| csi | Read-only | datacenter | no |
| csi | Read-only | compute cluster | yes |
| csi | `<cluster>-csi` | VM folder `<cluster>` | yes |
| csi | `<cluster>-csi` | CSI datastore(s) (`csi_datastore`; every member of a datastore cluster) | no |

Rules behind the layout:
- **The provisioner is confined to its folder.** Its VM privileges only exist on the `<cluster>` folder, so it
  can't touch other VMs.
- **Placement is a separate role.** VMs inherit permissions through the resource-pool hierarchy too. A role with
  `VirtualMachine.*` granted on the cluster with propagation would apply to every VM in it, so the cluster only
  gets `Resource.AssignVMToPool`.
- **The CSI user can't create or delete VMs.** Its credentials live in a Kubernetes secret.
- **Not granted:**
  - Tags and the storage policy: the administrator creates them in stage 1.
  - Global permissions on tag categories: vCenter logs harmless `System.Read` denials for the CSI user. Grant a
    global read-only permission only if you enable CSI topology/zones.
  - vSAN `Host.Config.Storage`: only needed for vSAN file volumes.

## Create or check them with Ansible
```bash
docker compose run --rm toolbox ansible-playbook playbooks/vcenter-access.yml --ask-vault-pass
docker compose run --rm toolbox ansible-playbook playbooks/vcenter-access.yml --ask-vault-pass --tags verify
```
The playbook is idempotent. It creates the users (passwords from the vault), the three roles, the folder and the
permissions above. It then reads the effective privileges back from vCenter and fails if any is missing. Rotate
passwords with `-e sso_reset_passwords=true`.

The privilege lists live in `roles/vcenter_bootstrap/defaults/main.yml` and the grants in
`roles/vcenter_bootstrap/vars/main.yml`. Keep this file in sync when they change.
