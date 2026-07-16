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
  # rule for -- e.g. 2 SGs x 2 prefix lists = 4 rules, not 2.
  sg_prefix_list_pairs = {
    for pair in setproduct(var.sg_ids, var.prefix_list_names) :
    "${pair[0]}-${pair[1]}" => {
      sg_id            = pair[0]
      prefix_list_name = pair[1]
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "cluster_access" {
  for_each = local.sg_prefix_list_pairs

  security_group_id = each.value.sg_id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.lookup[each.value.prefix_list_name].id
  ip_protocol        = var.ingress_protocol
  from_port          = var.ingress_port
  to_port            = var.ingress_port

  description = "eksmanager: ${each.value.prefix_list_name} to ${var.cluster_name}"
}
