# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# modules/identity_center — providers.tf
# -----------------------------------------------------------------------------
# This module spans two accounts:
#   default     — management account. IAM Identity Center (aws_ssoadmin_*) is
#                 enabled in the management account, so the Headlamp app
#                 registration must be created here.
#   aws.shared  — shared services account. The Headlamp OIDC config secret is
#                 read by EKSManagerAgentRole at runtime, which only has
#                 secretsmanager permissions scoped to the shared services
#                 account (see aws/modules/shared_services/agent-role-policy.json)
#                 — so the secret itself must be created there, not alongside
#                 the SSO application.
# -----------------------------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 5.0.0"
      configuration_aliases = [aws.shared]
    }
  }
}
