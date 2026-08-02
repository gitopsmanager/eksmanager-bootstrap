# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform/add-cluster — main.tf
# -----------------------------------------------------------------------------
# No prefix list creation or replacement here at all -- only data source
# lookups (by name; prefix list names are unique within an account/region,
# so this is unambiguous) and SG rule resources. This is deliberate: it
# keeps every cluster's blast radius limited to its own SG rules, and means
# adding/removing a cluster (or changing which prefix lists it references)
# never touches org-changes' state or resources, and vice versa.
#
# aws_vpc_security_group_ingress_rule (the modern, one-rule-per-resource
# type) rather than the older aws_security_group_rule -- changing
# prefix_list_id on one of these replaces only that specific rule (revoke
# old / authorize new), not the whole security group or every rule on it.
# -----------------------------------------------------------------------------

data "aws_ec2_managed_prefix_list" "lookup" {
  for_each = toset(var.prefix_list_names)
  name     = each.value
}

locals {
  # Every (security group, prefix list) combination this cluster needs a
  # rule for -- e.g. 2 SGs x 2 prefix lists = 4 rules, not 2. Split by what
  # the group is for, because the two want very different port ranges: see
  # the variable descriptions for why.
  eks_pairs = {
    for pair in setproduct(var.eks_sg_ids, var.prefix_list_names) :
    "${pair[0]}-${pair[1]}" => {
      sg_id            = pair[0]
      prefix_list_name = pair[1]
    }
  }

  nlb_pairs = {
    for pair in setproduct(var.nlb_sg_ids, var.prefix_list_names) :
    "${pair[0]}-${pair[1]}" => {
      sg_id            = pair[0]
      prefix_list_name = pair[1]
    }
  }
}

# API server only. The self-referencing rule EKS puts on this group carries
# everything the cluster needs internally, and is left untouched.
resource "aws_vpc_security_group_ingress_rule" "eks_api" {
  for_each = local.eks_pairs

  security_group_id = each.value.sg_id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.lookup[each.value.prefix_list_name].id
  ip_protocol       = var.ingress_protocol
  from_port         = var.eks_ingress_port
  to_port           = var.eks_ingress_port

  description = "eksmanager: ${each.value.prefix_list_name} to ${var.cluster_name} API"
}

# Every TCP port. The group starts with no rules at all, so these are the
# only way anything reaches the load balancer -- the prefix lists are what
# does the restricting, not the port range.
resource "aws_vpc_security_group_ingress_rule" "nlb_all_ports" {
  for_each = local.nlb_pairs

  security_group_id = each.value.sg_id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.lookup[each.value.prefix_list_name].id
  ip_protocol       = var.ingress_protocol
  from_port         = 0
  to_port           = 65535

  description = "eksmanager: ${each.value.prefix_list_name} to ${var.cluster_name} NLB"
}
