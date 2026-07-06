# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
output "headlamp_role_arn" {
  description = "ARN of EKSManagerHeadlampRole — assumed by the agent at runtime to manage the Headlamp OIDC app"
  value       = aws_iam_role.headlamp.arn
}
