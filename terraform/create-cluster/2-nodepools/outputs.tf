# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
output "bootstrap_pool" {
  value = var.bootstrap_pool ? {
    name           = aws_eks_node_group.bootstrap[0].node_group_name
    ami_type       = aws_eks_node_group.bootstrap[0].ami_type
    instance_types = aws_eks_node_group.bootstrap[0].instance_types
    asg            = aws_eks_node_group.bootstrap[0].resources[0].autoscaling_groups[0].name
  } : null
}
