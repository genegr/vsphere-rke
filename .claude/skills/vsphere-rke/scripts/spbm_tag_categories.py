"""List the tag categories (and their tags) that vCenter SPBM can use in tag-based policies.

Run inside the toolbox from the repo root:
    docker compose run --rm -T toolbox python3 -I .claude/skills/vsphere-rke/scripts/spbm_tag_categories.py

Reads vcenter_hostname / sso_domain from inventory/group_vars/all/main.yml (overridden by
overrides.yml when present) and the admin password from the vault (via .state/vault-pass),
so no secret appears on a command line.
If a category is missing here, the storage-policy task fails with "Unrecognized capability":
its associable types lack the urn:vim25 namespace (see the skill); re-run stage 1 --tags storage_policy.
"""
import os
import ssl
import subprocess

import yaml
from pyVim.connect import Disconnect, SmartConnect
from pyVmomi import SoapStubAdapter, VmomiSupport, pbm

TAG_NS = "http://www.vmware.com/storage/tag"

settings = yaml.safe_load(open("inventory/group_vars/all/main.yml"))
if os.path.exists("inventory/group_vars/all/overrides.yml"):
    settings.update(yaml.safe_load(open("inventory/group_vars/all/overrides.yml")) or {})
vault = yaml.safe_load(subprocess.run(
    ["ansible-vault", "view", "--vault-password-file", ".state/vault-pass",
     "inventory/group_vars/all/vault.yml"],
    check=True, capture_output=True, text=True).stdout)

host = settings["vcenter_hostname"]
si = SmartConnect(host=host, user="administrator@" + settings["sso_domain"],
                  pwd=vault["vault_vcenter_admin_password"], disableSslCertValidation=True)
try:
    VmomiSupport.GetRequestContext()["vcSessionCookie"] = si._stub.cookie.split('"')[1]
    stub = SoapStubAdapter(host=host, path="/pbm/sdk", version="pbm.version.version11",
                           sslContext=ssl._create_unverified_context())
    profile_manager = pbm.ServiceInstance("ServiceInstance", stub).RetrieveContent().profileManager
    metadata = profile_manager.FetchCapabilityMetadata(
        resourceType=pbm.profile.ResourceType(resourceType="STORAGE"))
    for category in metadata:
        for cap in category.capabilityMetadata:
            if cap.id.namespace != TAG_NS:
                continue
            tags = []
            for prop in cap.propertyMetadata or []:
                allowed = getattr(prop, "allowedValue", None)
                tags += [v.value for v in (getattr(allowed, "values", None) or [])]
            print(f"{cap.id.id}: {', '.join(tags)}")
finally:
    Disconnect(si)
