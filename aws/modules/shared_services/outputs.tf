# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
output "agent_role_arn"       { value = aws_iam_role.agent.arn }
output "agent_role_name"      { value = aws_iam_role.agent.name }
output "ecr_repository_url"   { value = aws_ecr_repository.app.repository_url }
