# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform/add-cluster — providers.tf
# -----------------------------------------------------------------------------
# One apply == one cluster, not one account/region pair -- a single account
# can have several clusters, each with its own state (see backend key
# below), so this never batches -- one build, one cluster. A single
# provider is all that needs: this cluster's account/region
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
  # per cluster rather than per account, so two clusters in the same account
  # can have their SG rules changed concurrently without one waiting on, or
  # being locked out by, the other's state lock.
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

locals {
  # Omitted rather than set empty when no prefix is configured -- see
  # variables.tf. merge() with an empty map adds nothing.
  environment_tag = var.dns_zone_prefix == "" ? {} : {
    "Environment" = var.dns_zone_prefix
  }
}

provider "aws" {
  region = var.target_region

  assume_role {
    role_arn     = "arn:aws:iam::${var.target_account_id}:role/${var.client_account_role_name}"
    session_name = "eksmanager-prefix-lists-add-cluster"
  }

  # "Managed By" is Terraform, not the agent or the server. The server
  # dispatches this build and the agent never touches these rules -- but what
  # actually creates them is this module, and the tag names the creator so that
  # "who do I ask to change this" has one answer.
  #
  # "Environment" is this cluster's DNS zone prefix rather than the flat
  # "production" the install-wide modules use: these rules belong to exactly one
  # cluster. The value arrives via clusters.json -> generate_add_cluster.py ->
  # cluster.auto.tfvars.json, and matches what the agent tagged the cluster and
  # its node groups with, so a cost report groups all of it together.
  default_tags {
    tags = merge({
      "Deployed By" = "GitOpsManager"
      "Managed By"  = "Terraform"
      "Module"      = "terraform-add-cluster"
      "Cluster"     = var.cluster_name
    }, local.environment_tag)
  }
}
