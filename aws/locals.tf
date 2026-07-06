# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform-aws-eksmanager — locals.tf
# -----------------------------------------------------------------------------
# Derived values computed from org_config.
# These are used across multiple submodules to avoid repeating the same
# flatten/merge logic in each one.
# -----------------------------------------------------------------------------

locals {
  # Flat map of account_id -> { ou_id, regions }
  # Used by the StackSet instances resource (one instance per account).
  account_ou_map = merge([
    for ou_id, accounts in var.org_config : {
      for account_id, regions in accounts : account_id => {
        ou_id   = ou_id
        regions = regions
      }
    }
  ]...)

  # Distinct union of all regions across all accounts.
  # Used as the StackSet-level AllowedRegions parameter.
  all_regions = distinct(flatten([
    for accounts in values(var.org_config) :
    flatten(values(accounts))
  ]))

  # Flat list of all OU IDs — used for SCP attachment.
  ou_ids = keys(var.org_config)

  # S3 bucket name is deterministic — derived from shared services account ID.
  config_bucket_name = "eks-manager-config-store-${var.shared_services_account_id}"
}
