# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
output "addon_versions" {
  value = merge(
    { (aws_eks_addon.pod_identity_agent.addon_name) = aws_eks_addon.pod_identity_agent.addon_version },
    { for k, a in aws_eks_addon.first_pass : a.addon_name => a.addon_version },
    { (aws_eks_addon.ebs_csi.addon_name) = aws_eks_addon.ebs_csi.addon_version },
  )
}

output "expected_addons" {
  description = "Every add-on this stage owns; the workflow's check fails if one is missing."
  value       = join(",", local.all_addons)
}
