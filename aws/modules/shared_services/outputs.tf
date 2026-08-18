# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
output "agent_role_arn" { value = aws_iam_role.agent.arn }
output "agent_role_name" { value = aws_iam_role.agent.name }
output "ecr_repository_url" { value = aws_ecr_repository.app.repository_url }

# The exact key, resolved at apply time from the alias this module already
# looks up. The SCP names it rather than arn:aws:kms:*:<acct>:key/*, which
# would match every key in the account -- including any the customer creates
# for their own state, ECR or anything else, blocking them from managing keys
# that have nothing to do with this product.
output "cmk_arn" {
  value       = data.aws_kms_key.eksmanager.arn
  description = "ARN of EKSManagerCMK, for the shared services SCP to protect by name"
}

# Surfaced so the name the agent derives can be checked against the one that
# was actually created, without digging through state.
output "log_bucket_name" { value = aws_s3_bucket.logs.bucket }

# Empty when no workload accounts are configured yet -- see the count on the role.
output "ecr_push_role_arn" {
  value       = try(aws_iam_role.ecr_push[0].arn, "")
  description = "Role in shared services that workload build runners chain into to create and push ECR repositories"
}
