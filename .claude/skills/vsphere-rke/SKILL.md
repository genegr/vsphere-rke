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

**Storage policy "Unrecognized capability … storage/tag".** SPBM (sps) doesn't know the tag category, because its
associable types are stored without the vSphere namespace. Run the SPBM probe: if the category is missing, re-run
`01-vcenter-bootstrap.yml --tags storage_policy`, which PATCHes the types to `urn:vim25:Datastore`/`urn:vim25:StoragePod`.
The policy then works within seconds. Don't wait, retry, or restart services for this.
Root cause (vCenter 8.0.3 build 24022515, 2026-10-16):
- **Stored type names:** the tagging service stores associable types as `QName{namespaceURI, localPart}`. The
  vSphere Client writes `urn:vim25:Datastore`. The public REST API stores exactly what it's given, and
  `vmware.vmware.tag_categories` and govc send bare `Datastore`, which leaves the namespace empty. SPBM only lists
  categories with the qualified type: for bare ones sps.log logs
  `CapabilityMetadataManagerImpl - Failed to fetch tag category InventoryServiceCategory:<id>`.
- **REST hides it:** `GET /api/cis/tagging/category/<id>` returns bare names in both cases. Only the internal
  invsvc API (vmodl1 `/invsvc/vmomi/sdk`, `InventoryServiceCategoryInfo.associableEntityType`) shows the
  namespace.
- **Why any GUI edit "fixed" it:** saving a category in the vSphere Client rewrites the types with the namespace.
  That's the effect we first attributed to the cardinality change.
- **Proof:** `POST /api/cis/tagging/category` with `associable_types: [urn:vim25:Datastore, urn:vim25:StoragePod]`
  makes the policy work on the first attempt. `PATCH` with the same list repairs an existing bare category.
  Cardinality, tag attachment and other tags on the datastore make no difference.
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
