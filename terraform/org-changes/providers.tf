# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform/org-changes — providers.tf
# -----------------------------------------------------------------------------
# One apply == one (account, region) pair, driven by the CodeBuild batch
# build-list (see iam/prefix-lists-pipeline-tf and the org-changes buildspec
# generator). Single provider, not the region-superset/multi-alias pattern
# considered earlier -- that problem only exists if one Terraform config
# has to fan out across many regions in a single apply. It doesn't here:
# the account/region fan-out already happened one level up, in the
# CodeBuild batch matrix, so this config only ever needs to reach exactly
# one target.
#
# No aws.shared provider, unlike aws/providers.tf -- this module has no
# need to read anything from the shared services account at apply time.
# The granular CIDR data (from the granular/groups config) is rendered by
# the Python generator into a .tfvars.json file bundled in the same zip as
# this module, not read live from S3 via a data source -- consistent with
# the buildspec itself being fully pre-rendered rather than dynamic.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.11.0" # use_lockfile (S3 native locking) is GA from 1.11

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }

  # bucket/region/key can't be set here -- backend blocks are evaluated
  # before any variable is available. All three are supplied via
  # -backend-config at `terraform init` time (buildspec.yml), keyed per
  # (account, region) pair: accounts/<account>/org-changes/<region>/terraform.tfstate.
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.target_region

  assume_role {
    role_arn     = "arn:aws:iam::${var.target_account_id}:role/${var.client_account_role_name}"
    session_name = "eksmanager-prefix-lists-org-changes"
  }

  default_tags {
    tags = {
      ManagedBy = "EKSManager"
      Module    = "terraform-org-changes"
    }
  }
}
