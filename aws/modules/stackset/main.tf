# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# modules/stackset — Steps 8 + 9
# Creates the StackSet skeleton (template registration) and deploys one
# instance per OU represented in org_config. Runs as DELEGATED_ADMIN from
# shared services. Terraform polls each operation natively.
#
# Per-account region restriction is baked into the CloudFormation template
# itself (Mappings: AccountRegionMap) rather than passed as a per-instance
# parameter override -- each account's own stack looks up its own entry via
# AWS::AccountId at deploy time. This means StackSet instances only ever
# need to target their OU, never a specific account within it -- the
# SERVICE_MANAGED permission model's simplest, most reliably-supported mode.
#
# Adding/removing an account: update topology.json's org_config and
# re-run the pipeline. Terraform's own for_each diffing over the distinct
# OU set (and the regenerated Mappings content) handles it -- no separate
# mechanism needed.
# -----------------------------------------------------------------------------

locals {
  # One StackSet instance per distinct OU represented in account_ou_map --
  # fully dynamic, not hardcoded to any specific OU.
  distinct_ous = toset([for account_id, info in var.account_ou_map : info.ou_id])

  # Renders the CloudFormation Mappings section content -- one entry per
  # account in account_ou_map, regardless of which OU it belongs to.
  # Spliced directly under "Mappings:\n  AccountRegionMap:" in the
  # template. Fully dynamic: no hardcoded accounts, OUs, or regions
  # anywhere in this module -- everything comes from account_ou_map, which
  # itself comes from the org_config the user passed into topology.json.
  account_region_mappings = join("\n", [
    for account_id, info in var.account_ou_map :
    "    \"${account_id}\":\n      AllowedRegions: \"${join(",", info.regions)}\""
  ])
}

resource "aws_cloudformation_stack_set" "enable_account" {
  name             = "EKSManagerEnableAccountStackSet"
  description      = "Deploys EKSManagerAdminRole with region restriction into each enabled spoke account"
  permission_model = "SERVICE_MANAGED"
  call_as          = "DELEGATED_ADMIN"
  template_body = templatefile("${path.module}/eksmanager-enable-account-stackset.yaml", {
    account_region_mappings = local.account_region_mappings
  })

  parameters = {
    SharedServicesAccountId = var.shared_services_account_id
  }

  auto_deployment {
    enabled                          = false
    retain_stacks_on_account_removal = false
  }

  capabilities = ["CAPABILITY_NAMED_IAM"]

  lifecycle {
    # Template or parameter changes update the definition but don't
    # redeploy existing instances automatically -- re-run the pipeline
    # to apply changes to existing accounts too.
    ignore_changes = []
  }
}

resource "aws_cloudformation_stack_set_instance" "accounts" {
  for_each = local.distinct_ous

  stack_set_name = aws_cloudformation_stack_set.enable_account.name
  call_as        = "DELEGATED_ADMIN"

  deployment_targets {
    organizational_unit_ids = [each.value]
  }

  # Terraform waits for each StackSet operation to complete before
  # moving to the next — gives real progress visibility in CI/CD output.
  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}
