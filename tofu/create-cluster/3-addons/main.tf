# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# Stage 3 of 4: the EKS add-ons and the Pod Identity associations.
#
# Every add-on is the newest version compatible with the cluster's
# Kubernetes version, on every apply. A re-run of the create (to fix a failed
# stage) therefore also upgrades any add-on that is behind, exactly as the
# upgrade does: driver fixes are wanted everywhere, new or existing.
#
# Order matters, and is the agent's:
#   1. eks-pod-identity-agent, vpc-cni, coredns, kube-proxy, metrics-server
#   2. the Pod Identity associations
#   3. aws-ebs-csi-driver, last. Started before the Pod Identity agent and
#      its association exist, it falls back to instance metadata and hangs in
#      CREATING with no health issue reported.
# -----------------------------------------------------------------------------

data "aws_eks_cluster" "this" {
  name = var.cluster.name
}

locals {
  first_pass = ["eks-pod-identity-agent", "vpc-cni", "coredns", "kube-proxy", "metrics-server"]
  all_addons = concat(local.first_pass, ["aws-ebs-csi-driver"])

  # namespace/serviceaccount -> role. external-dns's role is the customer's,
  # named in hosted-zones.json: EKS Manager never creates it.
  associations = {
    ebs_csi            = { namespace = "kube-system", sa = "ebs-csi-controller-sa", role = "arn:aws:iam::${var.cluster.account_id}:role/EKSManager-${var.cluster.name}-ebs-csi" }
    external_dns       = { namespace = "kube-system", sa = "external-dns", role = var.cluster.external_dns_role_arn }
    cluster_autoscaler = { namespace = "kube-system", sa = "cluster-autoscaler", role = "arn:aws:iam::${var.cluster.account_id}:role/EKSManager-${var.cluster.name}-cluster-autoscaler" }
    aws_lbc            = { namespace = "kube-system", sa = "aws-load-balancer-controller", role = "arn:aws:iam::${var.cluster.account_id}:role/EKSManager-${var.cluster.name}-aws-lbc" }
    # The operator's own service account (core-stack components/external-secrets).
    # It assumes EKSManagerAgentRole itself, through its ClusterSecretStore's
    # role setting, so no targetRoleArn here.
    eso = { namespace = "external-secrets", sa = "external-secrets", role = "arn:aws:iam::${var.cluster.account_id}:role/EKSManager-${var.cluster.name}-eso" }
    # The node group operator (core-stack components/ack-eks-controller);
    # its role is 1-cluster's module.ack_identity.
    ack = { namespace = "ack-system", sa = "ack-eks-controller", role = "arn:aws:iam::${var.cluster.account_id}:role/EKSManager-${var.cluster.name}-ack" }
  }
}

data "aws_eks_addon_version" "newest" {
  for_each           = toset(local.all_addons)
  addon_name         = each.value
  kubernetes_version = data.aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = data.aws_eks_cluster.this.name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = data.aws_eks_addon_version.newest["eks-pod-identity-agent"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = local.tags
}

resource "aws_eks_addon" "first_pass" {
  for_each = toset(["vpc-cni", "coredns", "kube-proxy", "metrics-server"])

  cluster_name                = data.aws_eks_cluster.this.name
  addon_name                  = each.value
  addon_version               = data.aws_eks_addon_version.newest[each.value].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = local.tags

  timeouts {
    create = "20m"
    update = "20m"
  }

  depends_on = [aws_eks_addon.pod_identity_agent]
}

resource "aws_eks_pod_identity_association" "this" {
  for_each = local.associations

  cluster_name    = data.aws_eks_cluster.this.name
  namespace       = each.value.namespace
  service_account = each.value.sa
  role_arn        = each.value.role
  tags            = local.tags

  depends_on = [aws_eks_addon.pod_identity_agent]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = data.aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = data.aws_eks_addon_version.newest["aws-ebs-csi-driver"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = local.tags

  # Every volume the driver creates -- every PVC, ECK's Elasticsearch data
  # included -- carries the cost tag (e.g. map-migrated). The add-on's own
  # tags above tag the add-on, not its volumes.
  configuration_values = var.runtime.cost_tag_name == "" ? null : jsonencode({
    controller = { extraVolumeTags = { (var.runtime.cost_tag_name) = var.runtime.cost_tag_value } }
  })

  timeouts {
    create = "20m"
    update = "20m"
  }

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_eks_pod_identity_association.this,
  ]
}
