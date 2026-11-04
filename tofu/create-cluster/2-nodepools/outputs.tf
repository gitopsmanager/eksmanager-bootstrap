# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
output "node_groups" {
  value = { for k, g in aws_eks_node_group.pool : k => {
    ami_type       = g.ami_type
    instance_types = g.instance_types
    asg            = g.resources[0].autoscaling_groups[0].name
  } }
}
