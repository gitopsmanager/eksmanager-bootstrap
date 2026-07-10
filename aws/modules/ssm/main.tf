# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# modules/ssm — Step 7
# Write EKSManager configuration to Parameter Store in shared services.
# -----------------------------------------------------------------------------

resource "aws_ssm_parameter" "shared_services_account" {
  name  = "/EKSManager/config/shared-services-account"
  type  = "String"
  value = var.shared_services_account_id
}

resource "aws_ssm_parameter" "shared_services_region" {
  name  = "/EKSManager/config/shared-services-region"
  type  = "String"
  value = var.shared_services_region
}

resource "aws_ssm_parameter" "mgmt_account" {
  name  = "/EKSManager/config/mgmt-account"
  type  = "String"
  value = var.management_account_id
}

resource "aws_ssm_parameter" "mgmt_account_region" {
  name  = "/EKSManager/config/mgmt-account-region"
  type  = "String"
  value = var.management_account_region
}

resource "aws_ssm_parameter" "agent_role_arn" {
  name  = "/EKSManager/config/agent-role-arn"
  type  = "String"
  value = var.agent_role_arn
}

resource "aws_ssm_parameter" "stackset_name" {
  name  = "/EKSManager/config/account-stackset-name"
  type  = "String"
  value = "EKSManagerEnableAccountStackSet"
}

resource "aws_ssm_parameter" "secrets_editing" {
  name  = "/EKSManager/config/secrets-editing"
  type  = "String"
  value = var.secrets_editing ? "true" : "false"
}

resource "aws_ssm_parameter" "app_url" {
  name  = "/EKSManager/config/app-url"
  type  = "String"
  value = var.app_url
}

resource "aws_ssm_parameter" "client_id" {
  name  = "/EKSManager/config/client-id"
  type  = "String"
  value = var.client_id
}

resource "aws_ssm_parameter" "cognito_url" {
  name  = "/EKSManager/config/cognito-url"
  type  = "String"
  value = var.cognito_url
}
