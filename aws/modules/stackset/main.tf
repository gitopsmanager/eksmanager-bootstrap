# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# modules/stackset — Steps 8 + 9
# Creates the StackSet skeleton (template registration) and deploys one
# instance per account in org_config. Runs as DELEGATED_ADMIN from
# shared services. Terraform polls each operation natively.
#
# Adding/removing an account: update topology.json's org_config and
# re-run the pipeline. Terraform's own for_each diffing over
# account_ou_map creates/removes the corresponding instance -- no
# separate mechanism needed.
# -----------------------------------------------------------------------------

resource "aws_cloudformation_stack_set" "enable_account" {
  name             = "EKSManagerEnableAccountStackSet"
  description      = "Deploys EKSManagerAdminRole with region restriction into each enabled spoke account"
  permission_model = "SERVICE_MANAGED"
  call_as          = "DELEGATED_ADMIN"
  template_body    = file("${path.module}/eksmanager-enable-account-stackset.yaml")

  parameters = {
    SharedServicesAccountId = var.shared_services_account_id
    AllowedRegions          = join(",", var.all_regions)
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
  for_each = var.account_ou_map

  stack_set_name = aws_cloudformation_stack_set.enable_account.name
  call_as        = "DELEGATED_ADMIN"

  deployment_targets {
    organizational_unit_ids = [each.value.ou_id]
    accounts                = [each.key]
    account_filter_type     = "INTERSECTION"
  }

  parameter_overrides = {
    AllowedRegions = join(",", each.value.regions)
  }

  # Terraform waits for each StackSet operation to complete before
  # moving to the next — gives real progress visibility in CI/CD output.
  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}
