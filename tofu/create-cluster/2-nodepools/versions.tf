# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# OpenTofu only (see tofu/README.md). One state per cluster per stage:
#   s3://eksmanager-clusters-<shared services account>/accounts/<account>/clusters/<cluster>/2-nodepools.tfstate
# supplied with -backend-config by bootstrap-create-cluster.yml.
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
