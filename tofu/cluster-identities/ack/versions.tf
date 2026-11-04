# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# OpenTofu only (see tofu/README.md). Its own state per cluster:
#   s3://eksmanager-clusters-<shared services account>/accounts/<account>/clusters/<cluster>/identity-ack.tfstate
# supplied with -backend-config by bootstrap-cluster-identities.yml.
terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}
