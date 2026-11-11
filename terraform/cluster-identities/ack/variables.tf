# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# Written by bootstrap-cluster-identities.yml as create.auto.tfvars.json.

variable "cluster" {
  type = object({
    name       = string
    account_id = string
    region     = string
  })
}

variable "runtime" {
  type = object({
    admin_role_name = string
    cost_tag_name   = optional(string, "")
    cost_tag_value  = optional(string, "")
  })
}
