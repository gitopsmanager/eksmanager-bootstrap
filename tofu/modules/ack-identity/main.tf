# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# The node group operator's identity: EKSManager-<cluster>-ack, the role the
# ACK eks-controller (core-stack components/ack-eks-controller) runs as
# through Pod Identity, creating, scaling and deleting the node groups written
# in the CD repo (infra/<cluster>/nodepools/).
#
# Used twice, so it is written once:
#   - tofu/create-cluster/1-cluster makes the role for a new cluster (its
#     association is in 3-addons, after the Pod Identity agent, as for every
#     other role there)
#   - tofu/cluster-identities/ack makes role AND association for a cluster
#     that already exists (bootstrap-cluster-identities.yml)
#
# Its own role, never the node role: every pod on a node can reach the node
# role through instance metadata, so the node role must not carry the power
# to reshape the cluster. Scoped to its one cluster: node groups in it, the
# cluster's own reads, and PassRole on that cluster's node role to EKS only.
#
# The account's EKSManagerRoleBoundary caps it (NodegroupOperator* there): a
# node group it creates must be born with EKSManager=Managed, and it can
# change or delete only node groups carrying that tag.
# -----------------------------------------------------------------------------

locals {
  role_name = "EKSManager-${var.cluster_name}-ack"
  cluster   = "arn:aws:eks:${var.region}:${var.account_id}:cluster/${var.cluster_name}"
  nodegroup = "arn:aws:eks:${var.region}:${var.account_id}:nodegroup/${var.cluster_name}/*/*"
  node_role = "arn:aws:iam::${var.account_id}:role/EKSManager-${var.cluster_name}-node"
}

# Pinned to this cluster (confused deputy), as every Pod Identity role in
# 1-cluster is: both SourceArn forms, the association id a wildcard because it
# does not exist until the association is created.
resource "aws_iam_role" "ack" {
  name                 = local.role_name
  permissions_boundary = var.boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.account_id }
        ArnLike = {
          "aws:SourceArn" = [
            "arn:aws:eks:${var.region}:${var.account_id}:podidentityassociation/${var.cluster_name}/*",
            local.cluster,
          ]
        }
      }
    }]
  })
  tags = merge(var.tags, { Name = local.role_name })
}

resource "aws_iam_role_policy" "ack" {
  name = "NodegroupOperator"
  role = aws_iam_role.ack.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Against the CLUSTER: creating a node group in it, listing them, and
        # the cluster read the controller makes before acting.
        Sid      = "ThisClusterNodegroups"
        Effect   = "Allow"
        Action   = ["eks:CreateNodegroup", "eks:ListNodegroups", "eks:DescribeCluster", "eks:ListUpdates", "eks:DescribeUpdate"]
        Resource = local.cluster
      },
      {
        # Against the NODE GROUP: this cluster's node groups only. TagResource
        # is how a create with tags is authorised, and how the file's tags
        # reach a node group; never UntagResource (the boundary refuses it too).
        Sid    = "ThisClusterNodegroupWrites"
        Effect = "Allow"
        Action = [
          "eks:DescribeNodegroup",
          "eks:DeleteNodegroup",
          "eks:UpdateNodegroupConfig",
          "eks:UpdateNodegroupVersion",
          "eks:DescribeUpdate",
          "eks:ListUpdates",
          "eks:TagResource",
          "eks:ListTagsForResource",
        ]
        Resource = local.nodegroup
      },
      {
        # A new node group's instances run as this cluster's node role, which
        # EKS needs passed to it -- that role, to EKS, and nothing else.
        Sid      = "PassThisClusterNodeRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = local.node_role
        Condition = {
          StringEquals = { "iam:PassedToService" = "eks.amazonaws.com" }
        }
      },
    ]
  })
}

# Only when the cluster already exists (cluster-identities). On a create, the
# association is made in 3-addons, after the Pod Identity agent add-on.
resource "aws_eks_pod_identity_association" "ack" {
  count = var.association ? 1 : 0

  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.ack.arn
  tags            = var.tags
}
