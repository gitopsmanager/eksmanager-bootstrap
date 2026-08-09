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
    private-hosted-zones.json must trust this ARN, or DNS-01 cannot write the
    challenge record. The buildspec fails in pre_build with the offending role
    named if that trust is missing.
  EOT
  value       = aws_iam_role.codebuild.arn
}

output "codebuild_project_name" {
  description = "CodeBuild project name, for triggering a run by hand."
  value       = aws_codebuild_project.lets_encrypt.name
}

output "assumable_cert_manager_roles" {
  description = "The cert_manager roles read from private-hosted-zones.json. This is the complete set EKSManagerLetsEncryptRole may assume — anything absent here cannot be reached."
  value       = local.cert_manager_role_arns
}
