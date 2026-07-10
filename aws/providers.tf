# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform-aws-eksmanager — providers.tf
# -----------------------------------------------------------------------------
# Two providers:
#   default    — management account, reached by assuming EKSManagerBootstrap
#                from CodeBuild's own role (EKSManagerBootstrapSharedRole,
#                in the shared services account)
#   aws.shared — shared services account. No assume_role -- CodeBuild's own
#                execution role already runs here directly.
#
# Child accounts are never targeted directly — the StackSet handles deployment
# into spoke accounts on behalf of the module.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }
}

# Management account — runner must authenticate here
provider "aws" {
  region = var.management_account_region

  assume_role {
    role_arn     = "arn:aws:iam::${var.management_account_id}:role/EKSManagerBootstrap"
    session_name = "EKSManagerBootstrap"
  }

  default_tags {
    tags = {
      ManagedBy = "EKSManager"
      Module    = "terraform-aws-eksmanager"
    }
  }
}

# Shared services account — CodeBuild's own execution role
# (EKSManagerBootstrapSharedRole) already runs here directly, so no
# assume_role hop is needed or used. Kept as a distinct provider alias
# (rather than just reusing the default provider) so callers stay explicit
# about which account a resource belongs to.
provider "aws" {
  alias  = "shared"
  region = var.shared_services_region

  default_tags {
    tags = {
      ManagedBy = "EKSManager"
      Module    = "terraform-aws-eksmanager"
    }
  }
}
