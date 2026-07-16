# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform/add-cluster — variables.tf
# -----------------------------------------------------------------------------

variable "target_account_id" {
  description = "12-digit AWS account ID this cluster lives in."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.target_account_id))
    error_message = "target_account_id must be a 12-digit AWS account ID."
  }
}

variable "target_region" {
  description = "AWS region this cluster lives in."
  type        = string
}

variable "client_account_role_name" {
  description = "IAM role name in the target account this module assumes. Same role, same trust requirement as terraform/org-changes -- see that module's variable of the same name."
  type        = string
  default     = "EKSManagerAdminRole"
}

variable "cluster_name" {
  description = "Name of the cluster this build targets. One build == one cluster; used for state-key context, resource tagging, and (by the buildspec, not this module) the success/failure callback."
  type        = string
}

variable "prefix_list_names" {
  description = <<-EOT
    Granular prefix list names to allow into this cluster's security
    groups. Already expanded from the cluster's selected group (e.g. "prod"
    -> ["corp_vpn", "office"]) by the Python generator using the groups
    mapping in the granular/groups config -- this module only ever sees a
    flat list of granular names, never a group name, and never touches the
    groups mapping itself.

    Each name must already exist as a deployed prefix list in this
    account/region -- created by terraform/org-changes, which runs
    separately and (by design) always ahead of any cluster referencing it,
    since org-changes deploys every granular list to every enabled
    account/region unconditionally. If a name here doesn't exist yet, the
    data source lookup below fails the apply outright rather than silently
    skipping it.
  EOT
  type        = list(string)
}

variable "sg_ids" {
  description = "Security group IDs to add rules to -- the cluster's NLB and EKS security groups, supplied by the GUI at cluster creation/edit time (it already knows these, since it created them)."
  type        = list(string)

  validation {
    condition     = length(var.sg_ids) > 0
    error_message = "sg_ids must contain at least one security group ID."
  }
}

variable "ingress_protocol" {
  description = "IP protocol for the ingress rules created below. Applied uniformly across every (security group, prefix list) pair -- not configurable per pair in this version."
  type        = string
  default     = "tcp"
}

variable "ingress_port" {
  description = "Port for the ingress rules created below (used as both from_port and to_port). Defaults to 443 -- the EKS API server / NLB HTTPS port most cluster-access use cases need. Applied uniformly across every (security group, prefix list) pair."
  type        = number
  default     = 443
}
