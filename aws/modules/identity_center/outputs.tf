# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
output "headlamp_app_arn" {
  description = "ARN of the Headlamp OIDC application in Identity Center. Stored in SSM and used by your app for runtime group assignments."
  value       = aws_ssoadmin_application.headlamp.application_arn
}

output "headlamp_issuer_url" {
  description = "Identity Center OIDC issuer URL for this instance."
  value       = local.issuer_url
}

output "headlamp_oidc_secret_arn" {
  description = "ARN of the Secrets Manager secret containing the Headlamp Kubernetes Secret JSON."
  value       = aws_secretsmanager_secret.headlamp_oidc.arn
}
