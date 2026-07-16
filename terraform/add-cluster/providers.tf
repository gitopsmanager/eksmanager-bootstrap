# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform/add-cluster — providers.tf
# -----------------------------------------------------------------------------
# One apply == one cluster, not one account/region pair -- a single account
# can have several clusters, each with its own state (see backend key
# below), so this doesn't batch the way org-changes does. Same single-
# provider shape as org-changes regardless: this cluster's account/region
# is already known literally by the time this runs (supplied by the GUI in
# the cluster-selection config, rendered into this build's variables by the
# Python generator), so there's nothing to fan out here either.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }

  # bucket/region/key supplied via -backend-config at `terraform init` time
  # (buildspec.yml), keyed per cluster:
  # accounts/<account>/clusters/<cluster>/terraform.tfstate -- deliberately
  # NOT accounts/<account>/org-changes/<region>/terraform.tfstate (that's
  # org-changes' own state), so a cluster's SG-rule changes never lock
  # against, or get locked out by, an org-wide granular-list rollout
  # running in the same account.
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.target_region

  assume_role {
    role_arn     = "arn:aws:iam::${var.target_account_id}:role/${var.client_account_role_name}"
    session_name = "eksmanager-prefix-lists-add-cluster"
  }

  default_tags {
    tags = {
      ManagedBy = "EKSManager"
      Module    = "terraform-add-cluster"
      Cluster   = var.cluster_name
    }
  }
}
