# vsphere-rke

Ubuntu 24.04 VMs on vSphere (OpenTofu) → RKE2 (Ansible, lablabs.rke2) → vSphere CPI + CSI + SPBM StorageClass.
Operating and debugging procedures: the `vsphere-rke` skill (`.claude/skills/vsphere-rke/SKILL.md`).
Human docs: `README.md`.

## Hard rules
- **Everything runs in the toolbox container** (`docker compose run --rm toolbox …`) on the jump box
  `<jumpbox>`. Never install tools on the jump box or in its home directory. The workstation (Windows)
  only edits files and syncs them over. A new tool means a new pinned stage/ARG in `docker/Dockerfile`.
- **No shell scripts.** Use Ansible modules or OpenTofu resources. Sanctioned exceptions:
  - `govc sso.user.*` in `roles/vcenter_bootstrap/tasks/users.yml` and `99-destroy.yml`, because no module manages SSO users.
  - `library/vm_vapp_config.py`, a custom module, because no module removes vApp config.
- **Least privilege.** Stage 1 is the only place that uses the SSO admin. Stage 2 authenticates as the
  provisioner and stage 4 as the CSI account. When something fails with NoPermission, add the *specific*
  privilege to `roles/vcenter_bootstrap/defaults/main.yml` and record why in
  `.claude/skills/vsphere-rke/references/privileges.md`. Never add `VirtualMachine.*` to a role granted on
  the cluster with propagation, because VMs inherit through resource pools.
- **Secrets never on a command line.** `community.general.terraform` echoes the full `-var` list on failure, so
  pass secrets as `TF_VAR_*` through `environment:`. Use `no_log: true` on tasks that carry passwords.
- **Pin every version**: Dockerfile ARGs, `docker/requirements.{txt,yml}`, `tofu/nodes/versions.tf`, `group_vars`.
- **Idempotent**: a second run of any stage must report no changes. Use declarative modules, and give
  command tasks `changed_when` guards.
- **Never commit** `.state/`, `inventory/group_vars/all/vault.yml` or `inventory/nodes.generated.yml`.

## Layout
```
compose.yaml, docker/            toolbox image (all tools pinned) — host networking (lab DNS overlaps docker0)
ansible.cfg                      inventory=inventory/, library=library/, ssh key .state/ssh/id_ed25519
inventory/hosts.yml              localhost + empty rke2_servers/rke2_agents groups
inventory/nodes.generated.yml    written by tofu (local_file) — node name -> IP
inventory/group_vars/all/        main.yml (ALL settings), vault.yml (encrypted secrets)
inventory/group_vars/k8s_cluster.yml   lablabs.rke2 settings
playbooks/01..04, site.yml, 99-destroy.yml
roles/vcenter_bootstrap          users, roles (privilege lists in defaults), folder, storage policy, permissions, template
roles/nodes                      ssh keypair + tofu apply/destroy + inventory refresh
roles/node_prep                  identity check, apt upgrade, multipath blacklist, reboot
roles/vsphere_cpi_csi            CPI (helm) + CSI (manifest) + StorageClass + smoke test
tofu/nodes                       vsphere_virtual_machine for_each over cp/worker map, cloud-init templates
library/vm_vapp_config.py        removes OVA vApp options from the template VM
```
**Adding a variable that tofu uses:** set the default in `group_vars/all/main.yml`, pass it in
`roles/nodes/tasks/main.yml` `variables:`, and declare it in `tofu/nodes/variables.tf`.

## Environment (lab)
- vCenter `vcenter.example.com` 8.0.3. The **SSO domain is `vsphere.local`**, not
  `vsphere.local`. Principals are written `VSPHERE.LOCAL\user` in permissions and `user@vsphere.local`
  for logins.
- Datacenter `Datacenter`. Clusters `Cluster` (default), `Cluster2` and `Cluster3` all mount
  `datastore1`. Network `VM Network` 192.0.2.0/24, gw .112.1, DHCP server 192.0.2.2,
  DNS 172.17.0.53.
- A policy called `other-team-policy` and other teams' objects already exist, so everything we create is
  `{{ cluster_name }}`-prefixed. vCenter is shared: don't touch objects without that prefix.

## Known gotchas (all verified)
- **Docker DNS**: `172.17.0.53` lies inside docker0's `172.17.0.0/16`, so the build and runs use host networking. Build
  with `docker buildx bake -f compose.yaml --allow=network.host toolbox`, because `docker compose build` can't grant the entitlement.
- **The image's ANSIBLE_ROLES_PATH overrides ansible.cfg**, so compose sets it to `/work/roles:/usr/share/ansible/roles`.
- **community.vmware 7.x** removed `vcenter_folder` (use `vmware.vmware.folder`) and deprecated the tag modules
  (use `vmware.vmware.tag_categories/tags/tag_associations`).
- **OVA vApp ISO transport**: the vSphere provider refuses to clone it without a client CD-ROM, and it would also
  let cloud-init's OVF datasource win over guestinfo. The template has its vApp config removed (`vm_vapp_config`).
- **The provider needs `VirtualMachine.Config.Rename`** for its post-clone reconfigure. Without it the clone is
  deleted again with a bare "Permission ... denied". Debug with `-e tofu_debug=true`.
- **DHCP + simultaneous reboots scramble IPs**: systemd-networkd sends a RELEASE on shutdown by default. cloud-init
  writes a networkd drop-in with `SendRelease=no` (DHCP mode only), and `node_prep/identity.yml` asserts that the
  hostname equals the inventory name before and after the reboot. RKE2 node names come from the inventory.
- **CPI chart always renders zone labels**: keep `cpi_region_tag_category`/`cpi_zone_tag_category` empty unless
  hosts/VMs carry those tags. Otherwise nodes never get a providerID.
- **CSI v3.7.4 controller affinity uses `Exists`** on `node-role.kubernetes.io/control-plane`, so RKE2's
  `"true"` label works without a patch.
- **SPBM tag sync**: a new tag category can stay invisible to SPBM (`Unrecognized capability`). The policy task
  retries for 20 minutes. On the lab vCenter (2026-10-15) restarting `sps` and `vpxd-svcs` did not help: SPBM only knew
  categories older than that day, so this is a VCSA-side issue. See the skill for the probe
  (`scripts/spbm_tag_categories.py`) and the `datastoreurl` workaround used to verify CSI.
  sps.log shows `Failed to fetch tag category …` for every category created that day: sps's internal tag cache
  never gets their details. This is a VMware SR, not a project bug.
- **Tag categories are ACL'd through global permissions.** vpxd-svcs logs a `System.Read` denial roughly every
  5 min for `svc-<cluster>-csi` on every tag category. This is harmless without CSI topology. Only add a global
  read-only permission for the CSI user if topology/zones are enabled.
- **lablabs.rke2 kubeconfig download** reports `changed` on every run. This is the only accepted non-idempotent task.
- **SSO password expiry** (90 days by default) breaks both service accounts. Rotate with
  `--tags users -e sso_reset_passwords=true`, then re-run stage 4.
