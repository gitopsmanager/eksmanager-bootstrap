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
  required_version = ">= 1.11.0" # use_lockfile (S3 native locking) is GA from 1.11; experimental-only in 1.10

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }

  # State lives in the same S3 bucket already used to store the
  # eksmanager-bootstrap.zip source (versioned, see
  # iam/codebuild-pipeline-tf/main.tf's aws_s3_bucket.bootstrap) under a
  # separate state/ prefix -- one less bucket to create and manage.
  # bucket/region can't be set here: backend blocks are evaluated before
  # any variable is available, so both are supplied via -backend-config at
  # `terraform init` time (buildspec.yml), computed from the same
  # shared_services_account_id/region already in pinned.auto.tfvars.json.
  # use_lockfile replaces the traditional DynamoDB lock table entirely --
  # no separate table to create or grant permissions on.
  backend "s3" {
    key          = "state/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

locals {
  # The customer's cost-allocation tag, merged into every provider's
  # default_tags. Omitted entirely when no key is configured -- an empty tag key
  # is rejected by the AWS API rather than ignored.
  extra_tags = var.resource_tag_name == "" ? {} : {
    (var.resource_tag_name) = var.resource_tag_value
  }

  # Keys are spaced because that is the form the customer's AWS reseller asked
  # for. Unusual, and awkward in IAM conditions -- "aws:RequestTag/Managed By"
  # -- but no condition anywhere keys off these, so the cost is only cosmetic.
  # The access boundary uses the separate EKSManager tag, which is untouched.
  #
  # "Managed By" names what CREATED the resource, not what asked for it. Every
  # resource in this module is Terraform's, so it is Terraform here. Resources
  # the agent creates directly through boto3 -- the EKS cluster, its node
  # groups -- carry EKSManagerAgent instead, and are tagged by the agent rather
  # than from here. The distinction matters for the prefix list rules: the
  # server dispatches that build, but Terraform is what creates them, so they
  # are Terraform too.
  #
  # "Environment" is production for everything in this module. These resources
  # -- the buckets, the pipelines, the shared roles -- serve every cluster the
  # installation manages, whatever environment each of those is. This IS the
  # production installation for the client. Per-cluster resources carry the DNS
  # zone prefix instead, set where they are created.
  #
  # ManagedBy (unspaced, "EKSManager") was removed in favour of "Managed By".
  # Keeping both left two near-identical keys with different values, which is a
  # trap in a cost report. Module stays -- it says something these do not.
  common_tags = merge({
    "Deployed By" = "GitOpsManager"
    "Managed By"  = "Terraform"
    "Environment" = "production"
    "Module"      = "terraform-aws-eksmanager"
  }, local.extra_tags)
}

# Management account — runner must authenticate here
provider "aws" {
  region = var.management_account_region

  assume_role {
    role_arn     = "arn:aws:iam::${var.management_account_id}:role/EKSManagerBootstrap"
    session_name = "EKSManagerBootstrap"
  }

  default_tags {
    tags = local.common_tags
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
    tags = local.common_tags
  }
}
