# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform/org-changes — variables.tf
# -----------------------------------------------------------------------------

variable "target_account_id" {
  description = "12-digit AWS account ID this build targets. One build == one account/region pair, supplied literally by the CodeBuild batch build-list (see the org-changes buildspec generator) -- never a list or a loop within this config."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.target_account_id))
    error_message = "target_account_id must be a 12-digit AWS account ID."
  }
}

variable "target_region" {
  description = "AWS region this build targets. Same one-pair-per-build note as target_account_id applies."
  type        = string
}

variable "client_account_role_name" {
  description = "IAM role name in the target account this module assumes to create prefix lists there. Must exist already (deployed by the aws/ bootstrap module's StackSet) and must trust EKSManagerPrefixListsSharedRole -- see aws/modules/stackset/eksmanager-enable-account-stackset.yaml."
  type        = string
  default     = "EKSManagerAdminRole"
}

variable "granular_lists" {
  description = <<-EOT
    Every granular prefix list to deploy to this account/region pair, keyed
    by list name. Deployed unconditionally -- every list in this map goes
    to every pair a build targets, per the "full coverage everywhere"
    design (no per-account/region filtering here; that's controlled by
    which pairs the CodeBuild matrix includes in the first place, driven by
    org-config.json's enabled accounts/regions).

    Rendered by the Python generator from the granular/groups config file
    into a .tfvars.json bundled in the same build artifact as this module --
    not read live from S3 at apply time. Example shape:
      {
        corp_vpn = [
          { cidr = "192.168.0.0/16", description = "corp vpn" }
        ]
        azure_cluster_cidrs = [
          { cidr = "10.5.0.0/16", description = "azure clusters" }
        ]
      }
  EOT
  type = map(list(object({
    cidr        = string
    description = string
  })))
}
