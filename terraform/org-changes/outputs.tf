# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
output "prefix_list_ids" {
  description = "Map of granular list name -> prefix list ID created in this account/region. Useful for build-log visibility; add-cluster looks these up independently by name, not through this output."
  value       = { for name, pl in aws_ec2_managed_prefix_list.granular : name => pl.id }
}
