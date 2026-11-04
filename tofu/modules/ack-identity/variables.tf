# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0

variable "cluster_name" {
  description = "The EKS cluster the operator manages node groups in."
  type        = string
}

variable "account_id" {
  description = "The cluster's account."
  type        = string
}

variable "region" {
  description = "The cluster's region."
  type        = string
}

variable "boundary_arn" {
  description = "EKSManagerRoleBoundary in the cluster's account; every EKSManager-* role is created with it."
  type        = string
}

variable "tags" {
  description = "The managed tags (EKSManager = Managed and the rest)."
  type        = map(string)
}

variable "association" {
  description = "Also make the Pod Identity association: true for an existing cluster, false on a create (3-addons makes it)."
  type        = bool
  default     = false
}

# The controller's service account, as components/ack-eks-controller installs
# it. 3-addons uses the same pair.
variable "namespace" {
  type    = string
  default = "ack-system"
}

variable "service_account" {
  type    = string
  default = "ack-eks-controller"
}
