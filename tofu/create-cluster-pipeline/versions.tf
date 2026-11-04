# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# OpenTofu only (see tofu/README.md). Run by setup-pipeline.sh, beside the
# iam/*-pipeline-tf modules and in the same way: management credentials,
# assuming shared_services_role_name into the shared services account. Its
# state sits with theirs, under a key no Terraform state uses:
#   s3://eksmanager-tfstate-<shared services account>/setup/create-cluster-pipeline/tofu.tfstate
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    key          = "setup/create-cluster-pipeline/tofu.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  assume_role {
    role_arn     = "arn:aws:iam::${var.shared_services_account_id}:role/${var.shared_services_role_name}"
    session_name = "eksmanager-create-cluster-pipeline-setup"
  }

  default_tags {
    tags = {
      "ManagedBy"   = "EKSManager"
      "Deployed By" = "GitOpsManager"
      "Managed By"  = "OpenTofu"
      "Module"      = "tofu-create-cluster-pipeline"
    }
  }
}
