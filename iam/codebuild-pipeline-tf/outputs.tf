# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
output "codebuild_project_name" {
  description = "Name of the CodeBuild project."
  value       = aws_codebuild_project.eksmanager_bootstrap.name
}

output "codebuild_role_arn" {
  description = "ARN of EKSManagerBootstrapSharedRole."
  value       = aws_iam_role.codebuild.arn
}

output "management_bootstrap_role_arn" {
  description = "ARN of EKSManagerBootstrap in the management account."
  value       = aws_iam_role.management_bootstrap.arn
}

output "eks_manager_user_view_permission_set_arn" {
  description = "ARN of the EKSManagerUserView permission set."
  value       = aws_ssoadmin_permission_set.eks_user_view.arn
}

output "eks_manager_user_admin_permission_set_arn" {
  description = "ARN of the EKSManagerUserAdmin permission set."
  value       = aws_ssoadmin_permission_set.eks_user_admin.arn
}

output "eks_manager_identity_center_role_arn" {
  description = "ARN of EKSManagerIdentityCenterRole -- EKSManagerAgentRole assumes this to create/delete account assignments."
  value       = aws_iam_role.identity_center.arn
}

output "identity_store_id" {
  description = "ID of the IAM Identity Center identity store, auto-discovered -- needed by EKSManagerAgentRole at runtime to resolve a group name to a GroupId via identitystore:GetGroupId."
  value       = local.identity_center_identity_store_id
}

output "bootstrap_bucket" {
  description = "Name of the S3 bucket used for bootstrap artifacts."
  value       = aws_s3_bucket.bootstrap.bucket
}

output "github_actions_role_arn" {
  description = "ARN to set as the AWS_ROLE_ARN repository variable on the fork, for .github/workflows/upload-to-s3.yml."
  value       = aws_iam_role.github_actions_upload.arn
}
