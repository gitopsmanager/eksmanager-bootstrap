# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform-aws-eksmanager — outputs.tf
# -----------------------------------------------------------------------------

output "agent_role_arn" {
  description = "ARN of the EKSManagerAgentRole in shared services"
  value       = module.shared_services.agent_role_arn
}

output "ecr_repository_url" {
  description = "ECR repository URL in shared services"
  value       = module.shared_services.ecr_repository_url
}

output "config_bucket_name" {
  description = "S3 config state bucket name in shared services"
  value       = local.config_bucket_name
}
