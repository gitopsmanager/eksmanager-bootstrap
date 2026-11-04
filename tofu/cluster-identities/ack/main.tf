# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# The node group operator's identity, for an EKS cluster that already exists
# (one the agent built). A cluster built by tofu/create-cluster gets it from
# 1-cluster and 3-addons instead.
#
# Create-if-missing, one identity per state: this state holds the ack role
# and its association and nothing else, so it can never change an identity
# some other component already uses. bootstrap-cluster-identities.yml checks
# first and skips when the role is already there -- it never imports,
# changes or replaces one.
# -----------------------------------------------------------------------------

module "ack_identity" {
  source = "../../modules/ack-identity"

  cluster_name = var.cluster.name
  account_id   = var.cluster.account_id
  region       = var.cluster.region
  boundary_arn = "arn:aws:iam::${var.cluster.account_id}:policy/EKSManagerRoleBoundary"
  tags         = local.tags
  association  = true
}
