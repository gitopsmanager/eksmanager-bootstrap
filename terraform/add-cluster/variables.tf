# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform/add-cluster — variables.tf
# -----------------------------------------------------------------------------

variable "target_account_id" {
  description = "12-digit AWS account ID this cluster lives in."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.target_account_id))
    error_message = "target_account_id must be a 12-digit AWS account ID."
  }
}

variable "target_region" {
  description = "AWS region this cluster lives in."
  type        = string
}

variable "client_account_role_name" {
  description = "IAM role name in the target account this module assumes. Must exist in every target account and trust the CodeBuild role that runs this module."
  type        = string
  default     = "EKSManagerAdminRole"
}

variable "cluster_name" {
  description = "Name of the cluster this build targets. One build == one cluster; used for state-key context, resource tagging, and (by the buildspec, not this module) the success/failure callback."
  type        = string
}

variable "prefix_list_names" {
  description = <<-EOT
    Prefix list names to allow into this cluster's security groups. Already
    expanded from the cluster's environment (e.g. "prod" -> ["corp_vpn",
    "office"]) by the Python generator using prefix-groups.json -- this
    module only ever sees a flat list of names, never an environment name,
    and never reads that file itself.

    Each name must already exist as a deployed prefix list in this account
    and region. Nothing here creates them: they are the customer's to manage,
    and this module only resolves them by name. If a name does not exist, the
    data source lookup below fails the apply outright rather than silently
    skipping it.
  EOT
  type        = list(string)
}

variable "eks_sg_ids" {
  description = <<-EOT
    IDs of the security group EKS creates and manages for the cluster. Not
    created here -- the GUI reads the id at cluster creation and passes it
    through clusters.json. This module only adds ingress rules to it.

    Gets one rule per prefix list on eks_ingress_port (443) and nothing else.
    Everything the cluster needs internally -- kubelet on 10250, CoreDNS,
    pod-to-pod across nodes, ephemeral ports -- already travels on the
    self-referencing rule EKS puts on this group, which the resources in
    main.tf never touch. The only thing an external prefix list needs in is
    the private API server endpoint.
  EOT
  type        = list(string)
  default     = []
}

variable "nlb_sg_ids" {
  description = <<-EOT
    IDs of the cluster's NLB frontend security groups. Not created here --
    the GUI creates "<cluster>-nlb-sg" at cluster creation and passes the id
    through clusters.json. This module only adds ingress rules to it.

    Gets every TCP port, because the prefix lists are what restrict access,
    not the port range -- Traefik fronts 80, 443 and the datastore ports
    behind it, and naming them here would mean a terraform edit every time
    the service gains a port.
  EOT
  type        = list(string)
  default     = []
}

variable "eks_ingress_port" {
  description = "Port allowed into eks_sg_ids from each prefix list. The EKS API server, so 443 unless something unusual is going on."
  type        = number
  default     = 443
}

variable "ingress_protocol" {
  description = "IP protocol for the ingress rules created below. Applied uniformly across every (security group, prefix list) pair -- not configurable per pair in this version."
  type        = string
  default     = "tcp"
}

# The DNS zone this cluster lives under, e.g. "dev". Becomes Environment=<prefix>
# on the rules this module creates, matching what the agent tags the cluster and
# its node groups with.
#
# Optional: a clusters.json entry written before this existed has no
# dns_zone_prefix, and an untagged rule is a gap in a cost report rather than a
# reason to fail the build. Empty omits the tag entirely -- an empty tag VALUE
# is legal in AWS but says nothing, and reads in a cost report as though the
# cluster genuinely has no environment.
variable "dns_zone_prefix" {
  description = "DNS zone prefix for the Environment tag. Empty omits the tag."
  type        = string
  default     = ""
}
