# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# Stage 2 of 4: the bootstrap node group -- the one pool the cluster runs on
# until its operator makes the real ones.
#
# The system and general pools are not made here. Once the core stack has
# installed the node pool operator (ACK eks-controller), the handover
# (bootstrap-handover.yml, started by the GUI) has the GUI render them into
# the CD repo, waits until ACK reports them Ready, and only then runs this
# stage again with bootstrap_pool false, which deletes this group: the
# system pods drain onto the operator's pools. So every pool is the
# operator's from the start, and nothing has to be adopted.
#
# Labelled sku=general with no taint, so Argo CD and the core stack schedule
# on it before the handover. A fixed size (min = max = desired): no
# autoscaler tags, nothing to scale while it lives.
# -----------------------------------------------------------------------------

data "aws_eks_cluster" "this" {
  name = var.cluster.name
}

data "aws_iam_role" "node" {
  name = "EKSManager-${var.cluster.name}-node"
}

locals {
  # The agent's infer_ami_type_for_eks, for current Kubernetes: AL2 has no
  # AMIs from 1.33, so GPU families take the AL2023 NVIDIA AMI instead of
  # AL2_X86_64_GPU. Everything else is AL2023, which is what EKS chose for
  # the agent by default.
  gpu_families = ["g4dn", "g5", "g6", "g6e", "p3", "p4d", "p4de", "p5"]
  arm_families = ["t4g", "m6g", "m6gd", "c6g", "c6gd", "c6gn", "r6g", "r6gd", "m7g", "c7g", "r7g", "x2g", "im4g", "is4g"]

  # The general pool's instance type and disk: it runs what general will.
  spec   = var.cluster.node_pools.general
  family = split(".", local.spec.instance_type)[0]
  ami_type = (
    contains(local.gpu_families, local.family) ? "AL2023_x86_64_NVIDIA" :
    contains(local.arm_families, local.family) ? "AL2023_ARM_64_STANDARD" :
    "AL2023_x86_64_STANDARD"
  )
}

resource "aws_eks_node_group" "bootstrap" {
  count = var.bootstrap_pool ? 1 : 0

  cluster_name    = data.aws_eks_cluster.this.name
  node_group_name = "bootstrap"
  node_role_arn   = data.aws_iam_role.node.arn
  subnet_ids      = var.cluster.subnet_ids
  version         = var.cluster.kubernetes_version

  instance_types = [local.spec.instance_type]
  capacity_type  = "ON_DEMAND"
  disk_size      = local.spec.disk_size
  ami_type       = local.ami_type

  scaling_config {
    min_size     = local.spec.count
    max_size     = local.spec.count
    desired_size = local.spec.count
  }

  labels = { sku = "general", "gitopsmanager.io/bootstrap" = "true" }

  # Terraform's while it lives: the agent and the GUI leave it alone.
  tags = merge(local.tags, { Name = "${var.cluster.name}-bootstrap", CreatedBy = "GitOpsManager-Terraform" })

  timeouts {
    create = "40m"
    update = "60m"
    delete = "40m"
  }

  lifecycle {
    ignore_changes = [version, scaling_config, ami_type, release_version]
  }
}

# The cost tag, propagated so every node instance carries it.
resource "aws_autoscaling_group_tag" "cost" {
  count                  = var.bootstrap_pool && var.runtime.cost_tag_name != "" ? 1 : 0
  autoscaling_group_name = aws_eks_node_group.bootstrap[0].resources[0].autoscaling_groups[0].name
  tag {
    key                 = var.runtime.cost_tag_name
    value               = var.runtime.cost_tag_value
    propagate_at_launch = true
  }
}
