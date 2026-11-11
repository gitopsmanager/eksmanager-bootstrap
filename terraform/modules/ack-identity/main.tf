# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# The node group operator's identity: EKSManager-<cluster>-ack, the role the
# ACK eks-controller (core-stack components/ack-eks-controller) runs as
# through Pod Identity, creating, scaling and deleting the node groups written
# in the CD repo (infra/<cluster>/nodepools/).
#
# Used twice, so it is written once:
#   - terraform/create-cluster/1-cluster makes the role for a new cluster (its
#     association is in 3-addons, after the Pod Identity agent, as for every
#     other role there)
#   - terraform/cluster-identities/ack makes role AND association for a cluster
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
  # The iam-controller's role (workload identities from the CD repo): its own,
  # so the role that reshapes node groups cannot also make IAM roles.
  iam_role_name = "EKSManager-${var.cluster_name}-ack-iam"
  # The roles it makes: this cluster's, under the app boundary (core-stack
  # tools/cd_identities.py names them EKSManager-app-<cluster>-<ns>-<name>).
  app_roles    = "arn:aws:iam::${var.account_id}:role/EKSManager-app-${var.cluster_name}-*"
  app_boundary = "arn:aws:iam::${var.account_id}:policy/EKSManagerAppBoundary"
  # And the platform components' roles, for a cluster created with
  # platform_identities on (core-stack components/platform-identities):
  # EKSManager-plat-<cluster>-{autoscaler,lbc,eso}, under their own boundary.
  platform_roles    = "arn:aws:iam::${var.account_id}:role/EKSManager-plat-${var.cluster_name}-*"
  platform_boundary = "arn:aws:iam::${var.account_id}:policy/EKSManagerPlatformBoundary"
  # The create's own control plane and node roles, handed to the
  # iam-controller at the handover (core-stack tools/cd_adopt.py). Still
  # under EKSManagerRoleBoundary; the only managed policies that can be
  # attached to them are the fixed list (what 1-cluster attached).
  cluster_roles = [
    "arn:aws:iam::${var.account_id}:role/EKSManager-${var.cluster_name}-control-plane",
    "arn:aws:iam::${var.account_id}:role/EKSManager-${var.cluster_name}-node",
  ]
  fixed_managed_policies = [
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
  ]
  pod_identity = "arn:aws:eks:${var.region}:${var.account_id}:podidentityassociation/${var.cluster_name}/*"
  access_entry = "arn:aws:eks:${var.region}:${var.account_id}:access-entry/${var.cluster_name}/*"
  cluster      = "arn:aws:eks:${var.region}:${var.account_id}:cluster/${var.cluster_name}"
  nodegroup    = "arn:aws:eks:${var.region}:${var.account_id}:nodegroup/${var.cluster_name}/*/*"
  node_role    = "arn:aws:iam::${var.account_id}:role/EKSManager-${var.cluster_name}-node"
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
        # Workload identities from the CD repo (core-stack tools/cd_identities.py):
        # this cluster's Pod Identity associations, linking a service account to
        # an EKSManager-* role -- one this cluster's iam-controller made, or a
        # shared one made outside ACK. Which roles may be passed is a setting
        # (var.pass_role_pattern): EKSManager-* here; a client's own install may
        # widen it.
        Sid    = "ThisClusterPodIdentities"
        Effect = "Allow"
        Action = [
          "eks:CreatePodIdentityAssociation",
          "eks:UpdatePodIdentityAssociation",
          "eks:DeletePodIdentityAssociation",
          "eks:DescribePodIdentityAssociation",
          "eks:ListPodIdentityAssociations",
          "eks:TagResource",
          "eks:ListTagsForResource",
        ]
        Resource = [local.cluster, local.pod_identity]
      },
      {
        Sid      = "PassWorkloadRoles"
        Effect   = "Allow"
        Action   = ["iam:PassRole", "iam:GetRole"]
        Resource = "arn:aws:iam::${var.account_id}:role/${var.pass_role_pattern}"
        Condition = {
          StringEqualsIfExists = { "iam:PassedToService" = "pods.eks.amazonaws.com" }
        }
      },
      {
        # EKS access entries from the CD repo (<cluster>/access/): the GUI's
        # SSO grants on this cluster.
        Sid    = "ThisClusterAccessEntries"
        Effect = "Allow"
        Action = [
          "eks:CreateAccessEntry",
          "eks:UpdateAccessEntry",
          "eks:DeleteAccessEntry",
          "eks:DescribeAccessEntry",
          "eks:ListAccessEntries",
          "eks:AssociateAccessPolicy",
          "eks:DisassociateAccessPolicy",
          "eks:ListAssociatedAccessPolicies",
        ]
        Resource = [local.cluster, local.access_entry]
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

# The ACK iam-controller (core-stack components/ack-iam-controller): makes
# this cluster's workload roles from the CD repo's templates. Only roles named
# EKSManager-app-<cluster>-*, and only with the EKSManagerAppBoundary
# permission boundary on them, which nothing here can take off or change: a
# file in the CD repo can never produce a role with more than the boundary
# allows. Pinned to this cluster like the ack role.
resource "aws_iam_role" "ack_iam" {
  name                 = local.iam_role_name
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
  tags = merge(var.tags, { Name = local.iam_role_name })
}

resource "aws_iam_role_policy" "ack_iam" {
  name = "WorkloadRoleOperator"
  role = aws_iam_role.ack_iam.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Born under the app boundary, or not at all.
        Sid      = "CreateBoundedRoles"
        Effect   = "Allow"
        Action   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
        Resource = local.app_roles
        Condition = {
          StringEquals = { "iam:PermissionsBoundary" = local.app_boundary }
        }
      },
      {
        # The platform roles: born under the platform boundary, or not at all.
        Sid      = "CreatePlatformRoles"
        Effect   = "Allow"
        Action   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
        Resource = local.platform_roles
        Condition = {
          StringEquals = { "iam:PermissionsBoundary" = local.platform_boundary }
        }
      },
      {
        Sid    = "ManageBoundedRoles"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:UpdateRole",
          "iam:UpdateRoleDescription",
          "iam:UpdateAssumeRolePolicy",
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListRoleTags",
          "iam:DeleteRole",
        ]
        Resource = [local.app_roles, local.platform_roles]
      },
      {
        # The cluster's own roles, adopted at the handover: their trust and
        # inline policies, and managed policies from the fixed list only.
        Sid    = "ManageClusterRoles"
        Effect = "Allow"
        Action = [
          "iam:GetRole",
          "iam:UpdateRole",
          "iam:UpdateRoleDescription",
          "iam:UpdateAssumeRolePolicy",
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListRoleTags",
        ]
        Resource = local.cluster_roles
      },
      {
        Sid      = "ClusterRolesFixedList"
        Effect   = "Allow"
        Action   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
        Resource = local.cluster_roles
        Condition = {
          ArnEquals = { "iam:PolicyARN" = local.fixed_managed_policies }
        }
      },
      {
        # Never the boundary off, never a policy of its own making, and never a
        # managed policy off the fixed list: what a role can do is its inline
        # policy (and, for the cluster's own roles, the fixed list), inside
        # its boundary.
        Sid      = "KeepTheBoundary"
        Effect   = "Deny"
        Action   = ["iam:DeleteRolePermissionsBoundary", "iam:CreatePolicy", "iam:CreatePolicyVersion"]
        Resource = "*"
      },
      {
        Sid      = "OnlyTheFixedList"
        Effect   = "Deny"
        Action   = "iam:AttachRolePolicy"
        Resource = "*"
        Condition = {
          ArnNotEquals = { "iam:PolicyARN" = local.fixed_managed_policies }
        }
      },
    ]
  })
}

# Only when the cluster already exists (cluster-identities). On a create, the
# association is made in 3-addons, after the Pod Identity agent add-on.
resource "aws_eks_pod_identity_association" "ack_iam" {
  count = var.association ? 1 : 0

  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = "ack-iam-controller"
  role_arn        = aws_iam_role.ack_iam.arn
  tags            = var.tags
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
