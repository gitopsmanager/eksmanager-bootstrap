# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# The workload account through EKSManagerAdminRole, with the create's session
# name, so the admin role's policies treat this exactly as a create stage.
provider "aws" {
  region = var.cluster.region

  assume_role {
    role_arn     = "arn:aws:iam::${var.cluster.account_id}:role/${var.runtime.admin_role_name}"
    session_name = "eksmanager-create-cluster"
  }
}

locals {
  # The managed tags, as tofu/create-cluster sets them. EKSManager=Managed is
  # the key the boundary and SCPs match on: never change it.
  cost_tag = var.runtime.cost_tag_name == "" ? {} : { (var.runtime.cost_tag_name) = var.runtime.cost_tag_value }
  tags = merge(
    {
      "EKSManager"  = "Managed"
      "Deployed By" = "GitOpsManager"
      "Managed By"  = "OpenTofu"
    },
    local.cost_tag,
  )
}
