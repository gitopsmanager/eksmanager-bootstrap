# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# modules/org — Steps 1 + 2
# Enable CloudFormation trusted access with Organizations and register
# shared services as delegated StackSet administrator.
# -----------------------------------------------------------------------------

resource "aws_organizations_aws_service_access" "cloudformation" {
  service_principal = "member.org.stacksets.cloudformation.amazonaws.com"
}

resource "aws_organizations_delegated_administrator" "stacksets" {
  account_id        = var.shared_services_account_id
  service_principal = "member.org.stacksets.cloudformation.amazonaws.com"

  depends_on = [aws_organizations_aws_service_access.cloudformation]
}
