# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
output "rule_ids" {
  description = "IDs of the security group rules created for this cluster. Build-log visibility only -- the buildspec's success/failure callback reports on apply exit status, not on this output's content."
  value       = { for key, rule in aws_vpc_security_group_ingress_rule.cluster_access : key => rule.security_group_rule_id }
}

output "prefix_list_ids_used" {
  description = "IDs of the prefix lists this cluster ended up referencing, resolved by name at apply time."
  value       = { for name, pl in data.aws_ec2_managed_prefix_list.lookup : name => pl.id }
}
