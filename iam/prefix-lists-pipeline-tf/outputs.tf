# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
output "codebuild_project_name" {
  description = "Name of the CodeBuild project."
  value       = aws_codebuild_project.eksmanager_prefix_lists.name
}

output "codebuild_role_arn" {
  description = "ARN of EKSManagerPrefixListsSharedRole."
  value       = aws_iam_role.codebuild.arn
}

output "prefix_lists_bucket" {
  description = "Name of the S3 bucket used for org-changes/add-cluster artifacts."
  value       = aws_s3_bucket.prefix_lists.bucket
}

output "github_actions_role_arn" {
  description = "ARN to set as the AWS_ROLE_ARN repository variable for org-changes.yml / add-cluster.yml, for the GitHub Actions OIDC upload path."
  value       = aws_iam_role.github_actions_upload.arn
}
