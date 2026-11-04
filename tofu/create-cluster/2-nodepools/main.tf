# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# Stage 2 of 4: the system (nodepool1) and general node groups, and the
# cluster-autoscaler's tags on their Auto Scaling Groups. Reproduces the
# agent's ensure_nodegroup (awsapi.py).
#
# Only these two pools come from the create. Every other pool is the GUI's,
# through the CD repo, and later changes to these two (size, type) are the
# GUI's too: the create only ever makes them.
#
# Create, then forget. Once this stage has applied, bootstrap-create-cluster.yml
# removes these node groups (and their ASG tags) from this stage's state
# without destroying them -- OpenTofu's "forget, destroy = false" -- so a
# destroy of the create can never take them, and they belong to the GUI and
# the node pool operator from then on. A re-run skips a pool that is in the
# cloud but no longer in this state (skip_pools, computed by the workflow), so
# it never makes one twice; a pool made by a run that failed half way is
# still in the state, and that re-run carries on with it.
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

  all_pools = {
    # The names, labels and taints the agent used. sku=nodepool1 with
    # CriticalAddonsOnly keeps everything but system add-ons off it.
    nodepool1 = {
      spec   = var.cluster.node_pools.system
      labels = { sku = "nodepool1" }
      taint  = { key = "CriticalAddonsOnly", value = "true" }
    }
    general = {
      spec   = var.cluster.node_pools.general
      labels = { sku = "general" }
      taint  = { key = "sku", value = "general" }
    }
  }
  # Forgotten pools (in the cloud, not in this state) are not made again.
  pools = { for k, p in local.all_pools : k => p if !contains(var.skip_pools, k) }

  ami_type = {
    for k, p in local.pools : k => (
      contains(local.gpu_families, split(".", p.spec.instance_type)[0]) ? "AL2023_x86_64_NVIDIA" :
      contains(local.arm_families, split(".", p.spec.instance_type)[0]) ? "AL2023_ARM_64_STANDARD" :
      "AL2023_x86_64_STANDARD"
    )
  }
}

resource "aws_eks_node_group" "pool" {
  for_each = local.pools

  cluster_name    = data.aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = data.aws_iam_role.node.arn
  subnet_ids      = var.cluster.subnet_ids
  version         = var.cluster.kubernetes_version

  instance_types = [each.value.spec.instance_type]
  capacity_type  = "ON_DEMAND"
  disk_size      = each.value.spec.disk_size
  ami_type       = local.ami_type[each.key]

  # min = max = desired, as the agent: the autoscaler moves desired within
  # what the GUI later sets.
  scaling_config {
    min_size     = each.value.spec.count
    max_size     = each.value.spec.count
    desired_size = each.value.spec.count
  }

  labels = each.value.labels

  taint {
    key    = each.value.taint.key
    value  = each.value.taint.value
    effect = "NO_SCHEDULE"
  }

  # Handed to the GUI and the agent once created, so tagged as the agent's:
  # the agent refuses to recreate, delete or upgrade a pool whose "Managed By"
  # is not its own (awsapi nodegroup_foreign_owner).
  #
  # CreatedBy says where it came from: this stage, which then forgot it.
  tags = merge(local.tags, { Name = "${var.cluster.name}-${each.key}", "Managed By" = "EKSManagerAgent", CreatedBy = "OpenTofu" })

  timeouts {
    create = "40m"
    update = "60m"
    delete = "40m"
  }

  # Never changed here: between this apply and the workflow forgetting it
  # (bootstrap-create-cluster.yml, "Forget the node pools"), and on a re-run
  # carrying on a failed one, the pool is already the GUI's to change.
  lifecycle {
    ignore_changes = all
  }
}

# On the Auto Scaling Group itself: the autoscaler's auto-discovery reads
# exactly these keys, and EKS does not copy node group tags onto it.
resource "aws_autoscaling_group_tag" "autoscaler_enabled" {
  for_each               = aws_eks_node_group.pool
  autoscaling_group_name = each.value.resources[0].autoscaling_groups[0].name
  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = false
  }
}

resource "aws_autoscaling_group_tag" "autoscaler_owned" {
  for_each               = aws_eks_node_group.pool
  autoscaling_group_name = each.value.resources[0].autoscaling_groups[0].name
  tag {
    key                 = "k8s.io/cluster-autoscaler/${var.cluster.name}"
    value               = "owned"
    propagate_at_launch = false
  }
}

# The cost tag, propagated so every node instance carries it.
resource "aws_autoscaling_group_tag" "cost" {
  for_each               = { for k, g in aws_eks_node_group.pool : k => g if var.runtime.cost_tag_name != "" }
  autoscaling_group_name = each.value.resources[0].autoscaling_groups[0].name
  tag {
    key                 = var.runtime.cost_tag_name
    value               = var.runtime.cost_tag_value
    propagate_at_launch = true
  }
}
