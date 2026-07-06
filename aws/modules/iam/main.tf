# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# modules/iam — Step 4
# Creates EKSManagerHeadlampRole in the management account.
#
# Trust:  headlamp-role-trust.json
#   - Only EKSManagerAgentRole in shared services can assume this role
#   - Uses ArnEquals condition for tight scoping
#
# Policy: headlamp-role-policy.json
#   - sso-admin:UpdateApplication + DescribeApplication on the Headlamp app ARN
#   - sso-admin:ListInstances + ListApplications (resource: *)
#
# Used at RUNTIME by the agent to manage the Headlamp OIDC app:
#   - Update redirect URIs when clusters are added
#   - The agent assumes this role from shared services
# -----------------------------------------------------------------------------

resource "aws_iam_role" "headlamp" {
  name        = "EKSManagerHeadlampRole"
  description = "Allows EKSManagerAgentRole in shared services to manage the Headlamp Identity Center OIDC app at runtime"

  assume_role_policy = templatefile("${path.module}/headlamp-role-trust.json", {
    SHARED_SERVICES_ACCOUNT_ID = var.shared_services_account_id
  })
}

resource "aws_iam_role_policy" "headlamp" {
  name = "EKSManagerHeadlampPolicy"
  role = aws_iam_role.headlamp.id

  policy = templatefile("${path.module}/headlamp-role-policy.json", {
    HEADLAMP_APP_ARN = var.headlamp_app_arn
  })
}
