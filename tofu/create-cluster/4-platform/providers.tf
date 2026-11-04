# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# Two AWS accounts:
#   aws        the workload account, through EKSManagerAdminRole
#   aws.shared the shared services account, where the EKSManager secrets
#              live, with the runner's own credentials (during the agent
#              migration, the EKSManagerAgentRole session the workflow
#              assumed -- exempt from the SCP that protects /EKSManager/*)
provider "aws" {
  region = var.cluster.region

  assume_role {
    role_arn     = "arn:aws:iam::${var.cluster.account_id}:role/${var.runtime.admin_role_name}"
    session_name = "eksmanager-create-cluster"
  }
}

provider "aws" {
  alias  = "shared"
  region = var.runtime.secrets_region
}

data "aws_eks_cluster" "this" {
  name = var.cluster.name
}

locals {
  admin_role_arn = "arn:aws:iam::${var.cluster.account_id}:role/${var.runtime.admin_role_name}"

  # aws eks get-token, assuming EKSManagerAdminRole: the role that created
  # the cluster, so it already has an admin access entry. The private
  # endpoint is reachable because the runner sits in the agent's subnet.
  kube_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", var.cluster.name,
      "--region", var.cluster.region,
      "--role-arn", local.admin_role_arn,
    ]
  }

  cost_tag = var.runtime.cost_tag_name == "" ? {} : { (var.runtime.cost_tag_name) = var.runtime.cost_tag_value }
  tags = merge(
    {
      "EKSManager"  = "Managed"
      "Deployed By" = "GitOpsManager"
      "Managed By"  = "OpenTofu"
      "Environment" = var.cluster.zone_prefix
    },
    local.cost_tag,
  )
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  exec {
    api_version = local.kube_exec.api_version
    command     = local.kube_exec.command
    args        = local.kube_exec.args
  }
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    exec                   = local.kube_exec
  }
}
