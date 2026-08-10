# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.

output "lets_encrypt_bucket" {
  description = "Artifact and Terraform state bucket. Set as the LETS_ENCRYPT_S3_BUCKET repository variable for the upload workflow."
  value       = aws_s3_bucket.lets_encrypt.bucket
}

output "github_actions_role_arn" {
  description = "Role the upload workflow assumes via OIDC. Set as the LETS_ENCRYPT_ROLE_ARN repository variable."
  value       = aws_iam_role.github_actions_upload.arn
}

output "codebuild_role_arn" {
  description = <<-EOT
    EKSManagerLetsEncryptRole. Every roles.cert_manager in
    hosted-zones.json must trust this ARN, or DNS-01 cannot write the
    challenge record. The buildspec fails in pre_build with the offending role
    named if that trust is missing.
  EOT
  value       = aws_iam_role.codebuild.arn
}

output "codebuild_project_name" {
  description = "CodeBuild project name, for triggering a run by hand."
  value       = aws_codebuild_project.lets_encrypt.name
}

output "policy_sync_role_arn" {
  description = "Role sync-hosted-zones.yml assumes via OIDC. Set as the LETS_ENCRYPT_POLICY_SYNC_ROLE_ARN repository variable. It may write one named inline policy on one role and nothing else."
  value       = aws_iam_role.policy_sync.arn
}
