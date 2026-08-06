# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
output "agent_role_arn" { value = aws_iam_role.agent.arn }
output "agent_role_name" { value = aws_iam_role.agent.name }
output "ecr_repository_url" { value = aws_ecr_repository.app.repository_url }

# Surfaced so the name the agent derives can be checked against the one that
# was actually created, without digging through state.
output "log_bucket_name" { value = aws_s3_bucket.logs.bucket }

# Empty when no workload accounts are configured yet -- see the count on the role.
output "ecr_push_role_arn" {
  value       = try(aws_iam_role.ecr_push[0].arn, "")
  description = "Role in shared services that workload build runners chain into to create and push ECR repositories"
}
