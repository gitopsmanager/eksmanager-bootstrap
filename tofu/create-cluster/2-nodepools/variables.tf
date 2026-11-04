# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# Both come from build/create-cluster/create.auto.tfvars.json, written by
# scripts/create_cluster.py prepare. Every stage takes the same two, so the
# workflow writes one file for all of them.

variable "cluster" {
  description = "The validated clusters/<name>.json, with the account, DNS zone and external-dns role resolved from hosted-zones.json."
  type = object({
    name                  = string
    account_id            = string
    region                = string
    kubernetes_version    = string
    zone_prefix           = string
    dns_zone              = string
    external_dns_role_arn = string
    prefix_list_group     = string
    subnet_ids            = list(string)
    service_cidr          = string
    node_pools = object({
      system  = object({ instance_type = string, count = number, disk_size = number })
      general = object({ instance_type = string, count = number, disk_size = number })
    })
    global_namespaces = list(string)
  })
}

variable "runtime" {
  description = "Values the workflow supplies: the shared services account and region, the runners' subnet, the admin role, the CD repo, the optional cost tag and the core-stack checkout."
  type = object({
    shared_services_account_id = string
    secrets_region             = string
    runner_subnet_cidr         = string
    admin_role_name            = string
    cd_repo_url                = string
    cost_tag_name              = optional(string, "")
    cost_tag_value             = optional(string, "")
    core_stack_dir             = optional(string, "")
  })
}

variable "skip_pools" {
  description = "Pools that exist in the cloud but not in this stage's state: made by an earlier run and forgotten. Never made again. Set by bootstrap-create-cluster.yml (TF_VAR_skip_pools)."
  type        = list(string)
  default     = []
}
