terraform {
  required_version = ">= 1.10.0"

  # State path is injected by Ansible (backend_config) so it lives in ./.state
  backend "local" {}

  required_providers {
    vsphere = {
      source  = "vmware/vsphere"
      version = "2.17.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "2.9.1"
    }
  }
}

provider "vsphere" {
  vsphere_server       = var.vcenter_server
  user                 = var.vcenter_user
  password             = var.vcenter_password
  allow_unverified_ssl = var.allow_unverified_ssl
}
