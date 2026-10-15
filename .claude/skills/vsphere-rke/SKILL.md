---
name: vsphere-rke
description: Develop, run, debug and extend the vsphere-rke project (vSphere VMs via OpenTofu + RKE2 + vSphere CPI/CSI via Ansible, all tools in a Docker toolbox on the jump box <jumpbox>). Use for any change to this repo, any deployment/teardown, privilege errors, CSI/CPI problems, or adding tools/variables.
---

# Working on vsphere-rke

Read `CLAUDE.md` first (hard rules and verified gotchas). This skill is the operating manual.

## 0. Where things run
- **Workstation** (Windows, this repo at `C:\path\to\vsphere-rke`): edit files only.
- **Jump box** `<jumpbox>` (Docker only), checkout at `~/vsphere-rke`. Every tool runs as
  `docker compose run --rm -T … toolbox <cmd>` there. Never install anything on the jump box itself.
- Jump-box-only files: `inventory/group_vars/all/vault.yml` (encrypted) and `.state/`, which holds:
  - `vault-pass` (mode 600)
  - `kubeconfig`
  - `ssh/id_ed25519` (node key)
  - `tofu/nodes.tfstate`
  - `cache/` (OVA) and `manifests/`
  Don't overwrite or delete them. Syncing never touches them, because they're excluded.

## 1. Sync the working tree (workstation → jump box)
Run from Git Bash on the workstation:
```bash
cd /c/path/to/vsphere-rke && tar --exclude=./.state --exclude=./.git -cf - . \
  | ssh -o BatchMode=yes <jumpbox> 'tar -xf - -C ~/vsphere-rke'
```
tar never deletes files, so after removing or renaming a file in the repo, also `rm` it on the jump box.

## 2. Run things
Use this prefix for any command. It's non-interactive and reads the vault password from `.state/vault-pass`:
```bash
ssh <jumpbox> 'cd ~/vsphere-rke && docker compose run --rm -T \
  -e ANSIBLE_VAULT_PASSWORD_FILE=/work/.state/vault-pass toolbox <cmd>'
```
| Goal | `<cmd>` |
|---|---|
| Full deploy / converge | `ansible-playbook playbooks/site.yml` |
| One stage | `ansible-playbook playbooks/0N-*.yml` (with `--tags …` for part of stage 1) |
| Dry run | append `--check --diff` (tofu tasks plan only) |
| kubectl / helm | `kubectl get nodes -o wide` (KUBECONFIG is preset) |
| govc (admin/prov/csi) | `ansible-playbook playbooks/tools/govc.yml -e "govc_args='ls /Datacenter/vm/rke2-01'" [-e govc_as=prov]`. Use `govc_as=prov` to check what the provisioner can actually see |
| Ad-hoc on nodes | `ansible k8s_cluster -m command -a "uptime"` |
| SPBM probe | `python3 -I .claude/skills/vsphere-rke/scripts/spbm_tag_categories.py` |
| Rebuild image | (no toolbox) `docker buildx bake -f compose.yaml --allow=network.host toolbox` |

Long runs (stage 3 takes about 10 min, a full rebuild about 25 min): run them in the background with output to
`.state/<name>.log`, then `grep -E "fatal|PLAY RECAP" -A8` the log.

**Destructive operations** need explicit user consent each time: `99-destroy.yml` and `force_template=true`, and
anything touching shared vCenter objects without the `{{ cluster_name }}` prefix or vCenter services (e.g. restarting sps).

## 3. Debug recipes
**NoPermission in stage 2 (OpenTofu).** The provider hides the privilege, so get it from the SOAP trace:
```bash
<prefix> ansible-playbook playbooks/02-nodes.yml -e tofu_debug=true -e control_plane_count=1 -e worker_count=0
ssh <jumpbox> 'cd ~/vsphere-rke && grep -rhoE "<privilegeId>[^<]+</privilegeId>" .state/vsphere-debug | sort | uniq -c; rm -rf .state/vsphere-debug'
```
First rule out a missing grant with `playbooks/vcenter-access.yml --tags verify`. Then add the privilege to
`roles/vcenter_bootstrap/defaults/main.yml` and run `playbooks/vcenter-access.yml`. Document it in
`docs/vcenter-user-profiles.md` and `references/privileges.md`. Repeat until the run succeeds.

**Storage policy "Unrecognized capability … storage/tag".** SPBM hasn't synced the tag category. Run the SPBM probe.
If the category is missing, ask the user before restarting vCenter services through
`POST https://<vc>/api/vcenter/services/<svc>?action=restart` (SSO admin session): first `sps`, then
`vpxd-svcs` followed by `sps`. Re-run `--tags storage_policy` afterwards.
Root-cause findings on the lab vCenter (2026-10-15, VCSA root shell, read-only + temporary DEBUG logging):
- `sps.log`: `CapabilityMetadataManagerImpl - Found 5 tag categories` then
  `Failed to fetch tag category InventoryServiceCategory:<id>` for every category created that day. There is
  no exception, even at DEBUG.
- sps serves tag categories from its own internal cache (the invsvc `FindKeyValues` calls in the envoy access
  log). The category IDs appear in that cache, but their details are never filled in. The datastore tag poller
  (`DatastoreTagChangePoller`, every 20 s) is healthy. Restarting `sps` and `vpxd-svcs` doesn't repopulate it.
- That needs a VMware SR. The sps loggers to raise for one are `com.vmware.pbm.capability`,
  `com.vmware.sps.pbm.impl.TagServiceImpl` and `com.vmware.vim.vmomi.client` in
  `/usr/lib/vmware-vpx/sps/conf/log4j2.properties`. They hot-reload (`monitorInterval=30`).
  Back up the file first and restore it afterwards.
History: on 2026-10-15 neither restart helped on the lab vCenter. SPBM listed only categories that existed before that
day, including none of a throwaway probe category. That points to SPBM's tag sync itself (sps ↔ tagging,
e.g. a solution-user or certificate problem), which needs `/var/log/vmware/vmware-sps/sps.log` on the VCSA.
To prove the CSI path while SPBM is down, use a temporary StorageClass with
`parameters.datastoreurl: ds:///vmfs/volumes/<uuid>/` (`playbooks/tools/govc.yml -e "govc_args='datastore.info <ds>'"`).

**Nodes don't get a providerID / keep the `uninitialized` taint.** Run
`kubectl -n kube-system logs -l app=vsphere-cpi --tail=50`:
- "region category … does not match": zone labels are set but the hosts/VMs aren't tagged.
- "provided node ip … not valid", or a VM matched to the wrong IP: the node names don't match the VMs (see the DHCP section).

**Node name ≠ VM (DHCP).** `node_prep` fails with "node IPs changed". Re-run `02-nodes.yml`, which refreshes
the inventory from tofu. If RKE2 was already installed with wrong names, the cluster must be rebuilt:
destroy the nodes and run stages 2–4.

**CSI.** Run `kubectl -n vmware-system-csi logs deploy/vsphere-csi-controller -c vsphere-csi-controller --tail=100`
and `kubectl get csinodes`. Use the smoke test: `04-vsphere-csi.yml -e csi_smoke_test=true`.

## 4. Verification checklist (run after any significant change)
1. Image: `toolbox sh -c 'tofu version; govc version; helm version --short; kubectl version --client; ansible --version | head -1'`
   matches the Dockerfile ARGs.
2. `site.yml` completes. A second run gives `changed=0` on every host, except the first control-plane node:
   lablabs.rke2 re-fetches and rewrites the kubeconfig every run (`changed=2`, accepted upstream behaviour).
   Tofu must report no changes.
3. `kubectl get nodes -o wide`: all Ready, node names = VM names, and
   `kubectl get nodes -o custom-columns=N:.metadata.name,P:.spec.providerID` all `vsphere://…`.
4. `kubectl -n vmware-system-csi get pods`: everything Running. `kubectl get csinodes` lists every node.
   `kubectl get sc` shows `vsphere-csi (default)`.
5. `04-vsphere-csi.yml -e csi_smoke_test=true`: the PVC is Bound and the pod becomes Ready (needs the storage policy).
6. Least privilege: stage 2 ran as `svc-<cluster>-prov`, and the CSI secret holds `svc-<cluster>-csi`. Grep the logs
   for "administrator" outside stage 1: there must be none.

## 5. Extending
- **New setting:** add it to `group_vars/all/main.yml` with a comment. If tofu uses it, also add it to
  `roles/nodes/tasks/main.yml` `variables:` and to `tofu/nodes/variables.tf`, with a validation where it makes sense.
- **New node pool / role:** extend the `locals` maps in `tofu/nodes/main.tf`, keyed by VM name so existing
  nodes keep their addresses. Add the group in `templates/inventory.yaml.tftpl` and in `inventory/hosts.yml`.
- **Bump a version:** edit the Dockerfile ARG or `requirements.*`, rebuild the image and re-run the verification.
  For RKE2, change `rke2_version` (lablabs does a rolling upgrade). For CSI, change `csi_version` and check
  the upstream manifest's affinity and namespace.
- **New containerized tool** (e.g. another installer): add a download stage and a `COPY --from` in the
  Dockerfile, pinned and checksum-verified. Or add a second compose service that shares `./:/work` and `.state/`.
  Never use `curl | sh` on the host.
- **vCenter rights for a new feature:** follow the NoPermission recipe; never fall back to admin credentials
  outside stage 1.

## References
- `docs/vcenter-user-profiles.md`: the minimum vCenter profiles (role → privilege → object), human-facing.
- `references/privileges.md`: why each non-obvious privilege exists, and how to find a missing one.
