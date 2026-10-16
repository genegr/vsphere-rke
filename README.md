# vsphere-rke

Deploys an **RKE2** Kubernetes cluster on **Ubuntu 24.04 VMs on vSphere**, then the **vSphere CPI and CSI** drivers
and a StorageClass backed by a tag-based **SPBM storage policy**.

Every tool (OpenTofu, Ansible, govc, Helm, kubectl) runs inside one container image built from this repo.
The jump box only needs Docker.

```
 jump box (Docker only)
 └─ toolbox container ──► stage 1  Ansible   vCenter bootstrap        (SSO admin)
                         ├► stage 2  OpenTofu  node VMs                 (provisioner account)
                         ├► stage 3  Ansible   OS prep + RKE2           (SSH key)
                         └► stage 4  Ansible   CPI + CSI + StorageClass (CSI account, stored in-cluster)
```

## What gets created

**In vCenter (stage 1, run as the SSO administrator):**
- Two SSO service accounts: `svc-<cluster>-prov`, used by OpenTofu only, and `svc-<cluster>-csi`, used by the
  in-cluster CPI/CSI only.
- Three least-privilege roles: `<cluster>-provisioner`, `<cluster>-placement` and `<cluster>-csi`, granted only
  on the objects they need. The minimum profiles are in
  [docs/vcenter-user-profiles.md](docs/vcenter-user-profiles.md), and `playbooks/vcenter-access.yml` creates
  and verifies them on their own.
- The VM folder `<cluster>`.
- The tag category `<cluster>-k8s-storage` and tag `<cluster>-csi-datastore`, attached to the CSI datastore.
- The tag-based storage policy `<cluster>-csi-policy`.
- The template `<cluster>-ubuntu-noble-tpl`, made from the Ubuntu cloud image OVA. It is never booted, and its vApp
  options are removed.

**Nodes (stage 2):** `control_plane_count` × `<cluster>-cp-NN` and `worker_count` × `<cluster>-wk-NN`, cloned with
`disk.EnableUUID`, hardware version 21 and cloud-init through guestinfo. DHCP is the default; static IPs are optional.

**Cluster (stages 3–4):**
- RKE2 (lablabs.rke2 role) with an external cloud provider.
- The vSphere CPI (Helm chart `vsphere-cpi`) and the vSphere CSI driver (upstream vanilla manifest).
- The StorageClass `vsphere-csi`, the default class, with `storagepolicyname: <cluster>-csi-policy`.

## Prerequisites
- A Linux host with Docker (Compose v2+, buildx) that can reach vCenter, the node network and the internet
  (GitHub, Docker Hub, PyPI, Ansible Galaxy, cloud-images.ubuntu.com, get.rke2.io).
- The vCenter SSO administrator password, used only by stage 1 and the bootstrap teardown.

## Quick start
```bash
git clone <this repo> vsphere-rke && cd vsphere-rke     # or copy it to the jump box

# 1. Build the toolbox image (host networking: see "Docker and the lab DNS" below)
docker buildx bake -f compose.yaml --allow=network.host toolbox

# 2. Secrets
mkdir -p .state/home && chmod 700 .state
cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml   # edit the values
docker compose run --rm toolbox ansible-vault encrypt inventory/group_vars/all/vault.yml

# 3. Review inventory/group_vars/all/main.yml (cluster name, datastore, counts, network mode...)

# 4. Deploy everything
docker compose run --rm toolbox ansible-playbook playbooks/site.yml --ask-vault-pass
```

The kubeconfig is written to `.state/kubeconfig`. The toolbox already points `KUBECONFIG` at it:
```bash
docker compose run --rm toolbox kubectl get nodes -o wide
```

For unattended runs, put the vault password in `.state/vault-pass` (mode 600) and add
`-e ANSIBLE_VAULT_PASSWORD_FILE=/work/.state/vault-pass` after `docker compose run --rm`.

## Stages
| Playbook | Does | Useful options |
|---|---|---|
| `playbooks/01-vcenter-bootstrap.yml` | SSO users, roles, folder, storage policy, permissions, template | `--tags users,roles,permissions,storage_policy,template`; `-e force_template=true`; `-e sso_reset_passwords=true` |
| `playbooks/02-nodes.yml` | `tofu apply` for the node VMs, writes `inventory/nodes.generated.yml` | `-e tofu_debug=true` (vSphere SOAP trace for privilege errors) |
| `playbooks/03-rke2.yml` | apt upgrade, multipath blacklist, RKE2 | — |
| `playbooks/04-vsphere-csi.yml` | CPI, CSI, StorageClass | `-e csi_smoke_test=true` (PVC + pod round trip) |
| `playbooks/site.yml` | 01 → 04 | — |
| `playbooks/vcenter-access.yml` | only the SSO users, roles, folder and permissions, then reads the effective privileges back | `--tags verify`; `-e sso_reset_passwords=true` |
| `playbooks/99-destroy.yml` | `tofu destroy` of the nodes | `-e destroy_volumes=true`, `-e destroy_bootstrap=true` |

Every stage is idempotent, so re-running it is safe and is the normal way to converge.

## Configuration
All variables live in [inventory/group_vars/all/main.yml](inventory/group_vars/all/main.yml) with generic defaults.
Put your lab's values in `inventory/group_vars/all/overrides.yml` (git-ignored; start from
[overrides.yml.example](inventory/group_vars/all/overrides.yml.example)). It's loaded after `main.yml`, so it wins.
The most important:

| Variable | Default | Notes |
|---|---|---|
| `cluster_name` | `rke2-01` | prefix for every vCenter object and VM name |
| `vcenter_hostname` / `sso_domain` | `vcenter.example.com` / `vsphere.local` | logins are `user@<sso_domain>` |
| `vsphere_datacenter` / `vsphere_cluster` | `Datacenter` / `Cluster` | |
| `vsphere_host` | `""` | ESXi host the node VMs and template are placed on; empty lets the cluster choose. With DRS this sets the initial placement only |
| `vsphere_resource_pool` | `""` | empty means the cluster root pool |
| `vsphere_datastore` | `datastore1` | node VM disks |
| `csi_datastore` | `= vsphere_datastore` | datastore or datastore cluster targeted by the storage policy |
| `vsphere_network` | `VM Network` | |
| `control_plane_count` / `worker_count` | `3` / `2` | the control-plane count must be odd |
| `cp_*` / `worker_*` | 4 vCPU, 8/16 GB, 60/100 GB | |
| `network_mode` | `dhcp` | `static` uses `static_cidr`, `static_ip_offset`, `static_gateway`, `dns_servers` |
| `rke2_version` | `v1.36.5+rke2r1` | |
| `rke2_api_vip` | `""` | empty means the first server's IP; set a free IP for keepalived HA |
| `csi_version` / `cpi_chart_version` | `v3.7.4` / `1.36.0` | |
| `storage_policy_name` / `storageclass_name` | `<cluster>-csi-policy` / `vsphere-csi` | |

Tool versions are pinned in [docker/Dockerfile](docker/Dockerfile) (build ARGs) and
[docker/requirements.*](docker/). Rebuild the image after changing them.

Static IPs example:
```yaml
network_mode: static
static_cidr: 192.0.2.0/24
static_ip_offset: 20          # nodes get 192.0.2.20, .21, ... (control plane first)
```

## Troubleshooting
- **`Unrecognized capability ... namespace = http://www.vmware.com/storage/tag`** when creating the storage policy:
  vCenter's storage policy service (sps) doesn't pick up a tag category created through the API, and waiting
  doesn't help. Stage 1 stops with this instruction: in the vSphere Client, open Tags & Custom Attributes →
  Categories → `<cluster>-k8s-storage` → Edit, set "Tags per object" to "Many tags" and save. Then re-run
  `01-vcenter-bootstrap.yml`. It's a one-time manual step per category.
- **`Permission to perform this operation was denied`** in stage 2: first run
  `playbooks/vcenter-access.yml --tags verify`. If every grant is present, re-run stage 2 with
  `-e tofu_debug=true` and find the privilege as described in
  [.claude/skills/vsphere-rke/references/privileges.md](.claude/skills/vsphere-rke/references/privileges.md).
  Then delete `.state/vsphere-debug`.
- **Node names/IPs don't match** (node_prep stops with "node IPs changed"): DHCP moved addresses between VMs.
  Re-run `02-nodes.yml` to refresh the inventory, and use DHCP reservations or `network_mode: static`.
- **CPI: "region category ... does not match any tags"**: zone labels are configured but the hosts/VMs aren't
  tagged. Leave `cpi_region_tag_category`/`cpi_zone_tag_category` empty unless you use topology.
- **SSO passwords expire** (default vCenter policy: 90 days). Rotate the vault values and run
  `01-vcenter-bootstrap.yml --tags users -e sso_reset_passwords=true`, then re-run stage 4 to refresh the
  in-cluster secrets.
- **Docker and the lab DNS**: if the lab resolver lies inside Docker's default bridge
  `172.17.0.0/16`, bridged containers can't resolve names. The toolbox therefore builds and runs with
  host networking. That's why the build uses `docker buildx bake --allow=network.host`; plain
  `docker compose build` refuses the `network.host` entitlement.
