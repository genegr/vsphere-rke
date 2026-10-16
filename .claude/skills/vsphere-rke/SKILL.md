---
name: vsphere-rke
description: Develop, run, debug and extend the vsphere-rke project (vSphere VMs via OpenTofu + RKE2 + vSphere CPI/CSI via Ansible, all tools in a Docker toolbox on the lab's jump box). Use for any change to this repo, any deployment/teardown, privilege errors, CSI/CPI problems, or adding tools/variables.
---

# Working on vsphere-rke

Read `CLAUDE.md` first (hard rules and verified gotchas). This skill is the operating manual.

## 0. Where things run
Lab addresses are in `CLAUDE.local.md` (git-ignored); below, `<jumpbox>` is the jump box's `user@host` and
`<repo>` the checkout on the workstation.
- **Workstation** (this repo at `<repo>`): edit files only.
- **Jump box** `<jumpbox>` (Docker only), checkout at `~/vsphere-rke`. Every tool runs as
  `docker compose run --rm -T … toolbox <cmd>` there. Never install anything on the jump box itself.
- Lab settings: `inventory/group_vars/all/overrides.yml` (git-ignored, synced from the workstation).
- Jump-box-only files: `inventory/group_vars/all/vault.yml` (encrypted) and `.state/`, which holds:
  - `vault-pass` (mode 600)
  - `kubeconfig`
  - `ssh/id_ed25519` (node key)
  - `tofu/nodes.tfstate`
  - `cache/` (OVA) and `manifests/`
  Don't overwrite or delete them. Syncing never touches them, because they're excluded.

## 1. Sync the working tree (workstation → jump box)
Run on the workstation (Git Bash on Windows):
```bash
cd <repo> && tar --exclude=./.state --exclude=./.git -cf - . \
  | ssh -o BatchMode=yes <jumpbox> 'tar -xf - -C ~/vsphere-rke'
```
tar never deletes files, so after removing or renaming a file in the repo, also `rm` it on the jump box.
If tar reports "file changed as we read it" (e.g. Claude Code writing under `.claude/`), the piped stream can arrive
broken ("does not look like a tar archive") and the jump box silently keeps old files. Write the archive to a temp
file first, then `ssh … 'tar -xf - -C ~/vsphere-rke' < archive.tar`, and grep the jump box for the change.

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
| govc (admin/prov/csi) | `ansible-playbook playbooks/tools/govc.yml -e "govc_args='ls /<datacenter>/vm/rke2-01'" [-e govc_as=prov]`. Use `govc_as=prov` to check what the provisioner can actually see |
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

**Storage policy "Unrecognized capability … storage/tag".** SPBM (sps) doesn't know the tag category. Stage 1 stops
with the fix: ask the user to edit the category once in the vSphere Client ("Tags per object" → "Many tags",
save), then re-run stage 1. The SPBM probe shows what SPBM knows. Don't wait, retry, or restart services for this.
Findings (vCenter 8.0.3 build 24022515, 2026-10-16, from vpxd-svcs.log + sps.log over a read-only root shell):
- **API-created categories:** every category created or edited through the public tagging API (vmware.vmware
  modules, govc) gets `CapabilityMetadataManagerImpl - Failed to fetch tag category InventoryServiceCategory:<id>`
  in sps.log. PbmCreate fails until something changes that. A second 8.0.3 lab showed the same message.
- **Ruled out:** cardinality (SINGLE/MULTIPLE), associable types, tag attachment (attached, unattached, untagged
  datastore), other categories/tags on the datastore, waiting (30+ min).
- **Also ruled out, the vSphere Client's own backend API:** vmodl1 `/invsvc/vmomi/sdk`, namespace
  `inventoryservice` 4.0: `InventoryServiceLogin`, `CreateInventoryServiceCategory`,
  `CreateInventoryServiceTag`, `UpdateInventoryServiceCategoryDescription`, including a single→multiple change.
  vpxd-svcs logs these as `vmodl.MoCategory`, the same as GUI edits, and SPBM still doesn't pick them up.
  The remaining difference is the GUI backend's SAML login (`InventoryServiceSamlLogin`); that hasn't been tested.
- **What works:** a vSphere Client edit of the category, observed 4 out of 4 times; the policy works within seconds.
- **History:** in March 2026 the same vCenter created another team's tag-based policy 8 s after an API-created category.
  So it worked once, and something cached in sps/vpxd-svcs since then differs. Cause unknown.
To prove the CSI path without SPBM, use a temporary StorageClass with
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
