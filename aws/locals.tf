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
  # Used by modules/stackset to derive the distinct set of OUs to target
  # (one StackSet instance per OU, not per account) and to generate the
  # CloudFormation template's per-account Mappings section.
  account_ou_map = merge([
    for ou_id, accounts in var.org_config : {
      for account_id, regions in accounts : account_id => {
        ou_id   = ou_id
        regions = regions
      }
    }
  ]...)

  # Flat list of all OU IDs — used for SCP attachment.
  ou_ids = keys(var.org_config)

  # S3 bucket name is deterministic — derived from shared services account ID.
  config_bucket_name = "eks-manager-config-store-${var.shared_services_account_id}"

  # allowed_regions.json content -- read by the agent (awsapi.py's
  # get_target_accounts_config) to populate the account/region pulldowns
  # when creating a cluster. Derived entirely from org_config so it never
  # drifts out of sync with topology.json -- previously nothing wrote this
  # file at all, so the bucket only ever stayed populated if someone
  # uploaded it by hand (and stayed empty forever after any teardown that
  # cleared the bucket, since nothing recreated it on re-apply).
  allowed_regions_json = jsonencode({
    target_ous = var.org_config
    regions    = distinct(flatten([for ou_id, accounts in var.org_config : flatten(values(accounts))]))
    accounts   = { for account_id, v in local.account_ou_map : account_id => v.regions }
  })
}
