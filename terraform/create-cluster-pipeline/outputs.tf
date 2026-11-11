# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
output "project_name" {
  description = "Set as the repository variable CREATE_CLUSTER_PROJECT. The project itself exists once project_created is true."
  value       = var.project_name
}

output "project_created" {
  value = var.codebuild_runner && var.service_role_ready
}

output "service_role_arn" {
  description = "The role the container runs as. TEMPORARY: EKSManagerAgentRole while run_as_agent_role is true."
  value       = local.service_role
}

output "state_bucket" {
  description = "Set as the repository variable CREATE_CLUSTER_STATE_BUCKET."
  value       = aws_s3_bucket.state.bucket
}

output "runner_role_arn" {
  description = "EKSManager-runner-create: the runner's own role, for when it stops running as the agent role."
  value       = aws_iam_role.runner.arn
}

output "connection_arn" {
  description = "The GitHub connection. Approve it in the console if it is PENDING, then re-run setup."
  value       = local.connection_arn
}

output "webhook_created" {
  value = var.codebuild_runner && var.service_role_ready && var.connection_ready
}

output "runner_subnet_cidr" {
  description = "Set as the repository variable RUNNER_SUBNET_CIDR."
  value       = data.aws_subnet.agent.cidr_block
}
