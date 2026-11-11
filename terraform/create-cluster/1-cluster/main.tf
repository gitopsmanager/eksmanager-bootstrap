# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# Stage 1 of 4: the cluster's IAM roles, the Traefik NLB's security group, the
# EKS cluster and the runners' 443 rule. Reproduces the agent's
# create_eks_cluster (packages/awsapi/awsapi.py) up to "wait cluster-active".
# -----------------------------------------------------------------------------

locals {
  name = var.cluster.name

  # Pod Identity: the EKS Pod Identity agent assumes these, so they trust the
  # service, not an OIDC provider -- pinned to this cluster and its account
  # (Prowler's confused-deputy finding; the agent's pod_identity_trust_policy
  # does the same). Both SourceArn forms, as alternatives, so the trust holds
  # whichever EKS presents and stays pinned to this cluster either way; the
  # association id is a wildcard because it does not exist until the
  # association is created, after the role.
  pod_identity_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.cluster.account_id }
        ArnLike = {
          "aws:SourceArn" = [
            "arn:aws:eks:${var.cluster.region}:${var.cluster.account_id}:podidentityassociation/${var.cluster.name}/*",
            "arn:aws:eks:${var.cluster.region}:${var.cluster.account_id}:cluster/${var.cluster.name}",
          ]
        }
      }
    }]
  })
}

data "aws_subnet" "first" {
  id = var.cluster.subnet_ids[0]
}

# ---------------------------------------------------------------- IAM roles
# All under EKSManagerRoleBoundary: the account StackSet refuses
# iam:CreateRole without it (DenyCreateRoleWithoutBoundary).

resource "aws_iam_role" "control_plane" {
  name                 = "EKSManager-${local.name}-control-plane"
  permissions_boundary = local.boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    # Pinned to this cluster (confused deputy), in the form the EKS docs give
    # for the cluster role. The node role below is not: EC2 instance roles do
    # not support these keys, and nodes would get no credentials.
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.cluster.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:eks:${var.cluster.region}:${var.cluster.account_id}:cluster/${var.cluster.name}" }
      }
    }]
  })
  tags = merge(local.tags, { Name = "EKSManager-${local.name}-control-plane" })

  # Made here, changed by the operator once the handover adopts it (core-stack
  # tools/cd_adopt.py): its trust, description and tags are the CD repo's from
  # then on, so a later apply never puts them back. Its managed policies'
  # attachments leave this state at the handover (bootstrap-handover.yml).
  lifecycle {
    ignore_changes = [assume_role_policy, description, tags, max_session_duration]
  }
}

resource "aws_iam_role_policy_attachment" "control_plane" {
  role       = aws_iam_role.control_plane.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "node" {
  name                 = "EKSManager-${local.name}-node"
  permissions_boundary = local.boundary_arn
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = merge(local.tags, { Name = "EKSManager-${local.name}-node" })

  # Made here, changed by the operator once the handover adopts it (core-stack
  # tools/cd_adopt.py): its trust, description and tags are the CD repo's from
  # then on, so a later apply never puts them back. Its managed policies'
  # attachments leave this state at the handover (bootstrap-handover.yml).
  lifecycle {
    ignore_changes = [assume_role_policy, description, tags, max_session_duration]
  }
}

# The agent's five. AutoScalingFullAccess is deliberately absent: the
# autoscaler has its own Pod Identity role (the operator's,
# core-stack components/platform-identities).
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
  ])
  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_iam_role" "ebs_csi" {
  name                 = "EKSManager-${local.name}-ebs-csi"
  permissions_boundary = local.boundary_arn
  assume_role_policy   = local.pod_identity_trust
  tags                 = merge(local.tags, { Name = "EKSManager-${local.name}-ebs-csi" })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# The cluster autoscaler's, the load balancer controller's and External
# Secrets' roles are not made here: the cluster's operator makes them once
# the core stack has installed it (core-stack components/platform-identities,
# EKSManager-plat-<cluster>-{autoscaler,lbc,eso} under
# EKSManagerPlatformBoundary). The operator's own roles (ACK, the
# eks-controller and iam-controller) are terraform/cluster-identities/ack, run by
# bootstrap-create-cluster.yml after 3-addons in their own state, so
# bootstrap-cluster-identities.yml's mode update is the only way they change.
# policies/aws-lbc.json stays as the source the platform boundary and the
# component's copy are refreshed from.


# ------------------------------------------------------- Traefik NLB group

# The AWS Load Balancer Controller finds it by its Name tag, and an NLB only
# accepts security groups when it is created, so it must exist before
# Traefik. No rules here: the add-cluster network pipeline adds them from the
# prefix lists. Created by a script, as the agent created it, not managed as a
# resource: see ensure-nlb-sg.sh.
resource "terraform_data" "nlb_sg" {
  # Re-run only if the group's identity changes; an existing group is left
  # alone either way (ensure-nlb-sg.sh).
  input = {
    name   = "${local.name}-nlb-sg"
    vpc_id = data.aws_subnet.first.vpc_id
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/ensure-nlb-sg.sh"
    environment = {
      ROLE_ARN       = "arn:aws:iam::${var.cluster.account_id}:role/${var.runtime.admin_role_name}"
      REGION         = var.cluster.region
      VPC_ID         = data.aws_subnet.first.vpc_id
      NAME           = "${local.name}-nlb-sg"
      DESCRIPTION    = "Frontend security group for the ${local.name} Traefik NLB"
      COST_TAG_NAME  = var.runtime.cost_tag_name
      COST_TAG_VALUE = var.runtime.cost_tag_value
    }
  }
}

data "aws_security_group" "nlb" {
  vpc_id = data.aws_subnet.first.vpc_id
  tags   = { Name = "${local.name}-nlb-sg" }

  depends_on = [terraform_data.nlb_sg]
}

# --------------------------------------------------------------- the cluster

resource "aws_eks_cluster" "this" {
  name     = local.name
  role_arn = aws_iam_role.control_plane.arn
  version  = var.cluster.kubernetes_version

  vpc_config {
    subnet_ids              = var.cluster.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  # API_AND_CONFIG_MAP, as the agent: it still reads aws-auth during the
  # migration, and the change to API-only is one-way.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  kubernetes_network_config {
    service_ipv4_cidr = var.cluster.service_cidr
    ip_family         = "ipv4"
  }

  # As the agent: EKS installs its own vpc-cni, coredns and kube-proxy, so the
  # node groups (stage 2) come up Ready before the managed add-ons (stage 3)
  # take those over. Without them a node has no network plugin and never
  # becomes Ready.
  bootstrap_self_managed_addons = true

  # As the agent: no control-plane logging, no KMS secrets encryption. Both
  # are worth deciding once, separately -- encryption cannot be turned off
  # again once on.

  tags = local.tags

  timeouts {
    create = "30m"
    update = "60m"
    delete = "30m"
  }

  # The version moves through the upgrade workflow (control plane first,
  # with its checks), never through a re-run of the create.
  lifecycle {
    ignore_changes = [version]
  }

  depends_on = [aws_iam_role_policy_attachment.control_plane]
}

# The runners sit in the agent's subnet, so this is the rule the agent
# created: 443 from that subnet's CIDR (a CIDR, because a cross-account
# security group reference may not resolve).
resource "aws_vpc_security_group_ingress_rule" "runners" {
  security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  description       = "EKS Manager agent subnet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.runtime.runner_subnet_cidr
  tags              = local.tags
}
