# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_arn" {
  value = aws_eks_cluster.this.arn
}

output "vpc_id" {
  value = data.aws_subnet.first.vpc_id
}

output "subnet_ids" {
  value = var.cluster.subnet_ids
}

output "cluster_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "nlb_security_group_id" {
  value = data.aws_security_group.nlb.id
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "pod_identity_role_arns" {
  value = {
    cluster_autoscaler = aws_iam_role.cluster_autoscaler.arn
    ebs_csi            = aws_iam_role.ebs_csi.arn
    aws_lbc            = aws_iam_role.aws_lbc.arn
    eso                = aws_iam_role.eso.arn
    ack                = module.ack_identity.role_arn
  }
}
