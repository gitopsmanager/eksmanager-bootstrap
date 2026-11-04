# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# The workload account, through EKSManagerAdminRole, as every agent create
# does. The credentials this starts from are the runner's (during the agent
# migration, an EKSManagerAgentRole session the workflow assumed). Each stage
# is its own apply with fresh credentials, which keeps every run inside the
# one-hour cap on chained role sessions.
provider "aws" {
  region = var.cluster.region

  assume_role {
    role_arn     = "arn:aws:iam::${var.cluster.account_id}:role/${var.runtime.admin_role_name}"
    session_name = "eksmanager-create-cluster"
  }
}

locals {
  # The agent's managed_tags_map (awsapi.py), with "Managed By" naming
  # OpenTofu, the creator. EKSManager=Managed is the IAM-condition key the
  # boundary and SCPs match on: never change it.
  cost_tag = var.runtime.cost_tag_name == "" ? {} : { (var.runtime.cost_tag_name) = var.runtime.cost_tag_value }
  tags = merge(
    {
      "EKSManager"  = "Managed"
      "Deployed By" = "GitOpsManager"
      "Managed By"  = "OpenTofu"
      "Environment" = var.cluster.zone_prefix
    },
    local.cost_tag,
  )
  boundary_arn = "arn:aws:iam::${var.cluster.account_id}:policy/EKSManagerRoleBoundary"
}
