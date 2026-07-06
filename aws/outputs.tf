# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform-aws-eksmanager — outputs.tf
# -----------------------------------------------------------------------------

output "headlamp_role_arn" {
  description = "ARN of EKSManagerHeadlampRole in management account — assumed by agent to manage Headlamp OIDC app at runtime"
  value       = module.iam.headlamp_role_arn
}

output "headlamp_app_arn" {
  description = "ARN of the Headlamp OIDC application in Identity Center"
  value       = module.identity_center.headlamp_app_arn
}

output "headlamp_issuer_url" {
  description = "Identity Center OIDC issuer URL — used in Headlamp config"
  value       = module.identity_center.headlamp_issuer_url
}

output "headlamp_oidc_secret_arn" {
  description = "Secrets Manager ARN containing the Headlamp Kubernetes Secret JSON"
  value       = module.identity_center.headlamp_oidc_secret_arn
}

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
