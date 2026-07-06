# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# modules/scp — Step 5 (SCP)
# Creates and attaches the EKSManager protection SCP to each OU in org_config.
# Only deployed when var.manage_scp_automatically = true (default).
#
# eksmanager-scp.json uses {{SHARED_SERVICES_ACCOUNT_ID}} tokens (same as
# aws-bootstrap.py). We replace them with replace() before applying.
# -----------------------------------------------------------------------------

locals {
  scp_content = replace(
    file("${path.module}/eksmanager-scp.json"),
    "{{SHARED_SERVICES_ACCOUNT_ID}}",
    var.shared_services_account_id
  )
}

resource "aws_organizations_policy" "eksmanager" {
  name        = "EKSManagerProtectionSCP"
  description = "Protects EKSManager components inside the consolidated Shared Services architecture"
  type        = "SERVICE_CONTROL_POLICY"
  content     = local.scp_content
}

resource "aws_organizations_policy_attachment" "eksmanager" {
  for_each = toset(var.ou_ids)

  policy_id = aws_organizations_policy.eksmanager.id
  target_id = each.value
}
