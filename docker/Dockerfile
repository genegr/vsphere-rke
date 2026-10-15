# syntax=docker/dockerfile:1
# vsphere-rke toolbox: every tool the project needs, pinned, in one image.
# Nothing is installed on the jump box itself.

ARG PYTHON_IMAGE=python:3.13-slim

# --- static binaries --------------------------------------------------------
FROM ${PYTHON_IMAGE} AS bins
ARG TOFU_VERSION=1.13.1
ARG GOVC_VERSION=0.55.2
ARG HELM_VERSION=3.22.0
ARG KUBECTL_VERSION=1.37.1
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /dl
RUN set -eux; \
    curl -fsSLO "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_amd64.zip"; \
    curl -fsSLO "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_SHA256SUMS"; \
    sha256sum -c --ignore-missing "tofu_${TOFU_VERSION}_SHA256SUMS"; \
    unzip -o "tofu_${TOFU_VERSION}_linux_amd64.zip" tofu -d /out; \
    curl -fsSLO "https://github.com/vmware/govmomi/releases/download/v${GOVC_VERSION}/govc_Linux_x86_64.tar.gz"; \
    curl -fsSLO "https://github.com/vmware/govmomi/releases/download/v${GOVC_VERSION}/checksums.txt"; \
    sha256sum -c --ignore-missing checksums.txt; \
    tar -xzf govc_Linux_x86_64.tar.gz -C /out govc; \
    curl -fsSLO "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz"; \
    echo "$(curl -fsSL https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz.sha256sum)" | sha256sum -c; \
    tar -xzf "helm-v${HELM_VERSION}-linux-amd64.tar.gz" --strip-components=1 -C /out linux-amd64/helm; \
    curl -fsSLo /out/kubectl "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl"; \
    echo "$(curl -fsSL https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256)  /out/kubectl" | sha256sum -c; \
    chmod 0755 /out/*

# --- toolbox ----------------------------------------------------------------
FROM ${PYTHON_IMAGE}
LABEL org.opencontainers.image.title="vsphere-rke-toolbox"
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates openssh-client git \
 && rm -rf /var/lib/apt/lists/*
COPY --from=bins /out/ /usr/local/bin/
COPY requirements.txt requirements.yml /tmp/
RUN pip install --no-cache-dir -r /tmp/requirements.txt
# Collections and roles go to the system-wide path, never to a home directory.
ENV ANSIBLE_COLLECTIONS_PATH=/usr/share/ansible/collections \
    ANSIBLE_ROLES_PATH=/usr/share/ansible/roles
RUN ansible-galaxy collection install -r /tmp/requirements.yml -p /usr/share/ansible/collections \
 && ansible-galaxy role install -r /tmp/requirements.yml -p /usr/share/ansible/roles \
 && rm -rf /root/.ansible
# ssh needs a passwd entry for the runtime uid; HOME points into the bind-mounted ./.state
ARG TOOLBOX_UID=1000
ARG TOOLBOX_GID=1000
RUN groupadd -g ${TOOLBOX_GID} toolbox \
 && useradd -u ${TOOLBOX_UID} -g ${TOOLBOX_GID} -M -d /work/.state/home -s /bin/bash toolbox
WORKDIR /work
CMD ["bash"]
