# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform/org-changes — main.tf
# -----------------------------------------------------------------------------
# One aws_ec2_managed_prefix_list per entry in var.granular_lists, in this
# build's target account/region. max_entries is set exactly to each list's
# entry count (not padded with headroom) because entries and max_entries
# can't change in the same in-place update -- instead of the two-apply
# workaround, this always REPLACES the prefix list on any entry change
# (create_before_destroy + replace_triggered_by), which is the design we
# settled on: connection tracking means existing traffic isn't dropped by a
# security group rule swap, only new connection attempts during the brief
# revoke/authorize window are at any risk, and only for the specific list
# that changed.
#
# Because add-cluster's SG rules reference these lists by NAME (via a
# data "aws_ec2_managed_prefix_list" lookup, not this module's own resource
# reference), and because this module and add-cluster run as separate
# Terraform states, the ID churn from a replace is invisible to add-cluster
# -- it always looks up whatever ID currently has this name, so it never
# holds a stale reference the way a hardcoded ID would.
# -----------------------------------------------------------------------------

resource "aws_ec2_managed_prefix_list" "granular" {
  for_each = var.granular_lists

  name           = each.key
  address_family = "IPv4"
  max_entries    = length(each.value)

  dynamic "entry" {
    for_each = each.value
    content {
      cidr        = entry.value.cidr
      description = entry.value.description
    }
  }

  lifecycle {
    create_before_destroy = true
    replace_triggered_by  = [terraform_data.granular_hash[each.key]]
  }
}

# Changes whenever a given list's entries change at all (add, remove, edit
# any CIDR) -- what actually forces aws_ec2_managed_prefix_list.granular to
# replace, since Terraform doesn't infer "this resource should replace"
# from a plain entry diff on its own quirky enough attribute nesting to be
# forced explicitly here.
resource "terraform_data" "granular_hash" {
  for_each = var.granular_lists
  input    = sha256(jsonencode(each.value))
}
