# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform-aws-eksmanager — providers.tf
# -----------------------------------------------------------------------------
# Two providers:
#   default    — management account, reached by assuming EKSManagerBootstrap
#                from CodeBuild's own role (EKSManagerBootstrapSharedRole,
#                in the shared services account)
#   aws.shared — shared services account (assumed via
#                shared_services_role_name, resolved in buildspec.yml)
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

# Shared services account — assumed from management account
provider "aws" {
  alias  = "shared"
  region = var.shared_services_region

  assume_role {
    role_arn     = "arn:aws:iam::${var.shared_services_account_id}:role/${var.shared_services_role_name}"
    session_name = "EKSManagerBootstrap"
  }

  default_tags {
    tags = {
      ManagedBy = "EKSManager"
      Module    = "terraform-aws-eksmanager"
    }
  }
}
