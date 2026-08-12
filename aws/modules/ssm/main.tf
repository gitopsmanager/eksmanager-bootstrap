# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# modules/ssm — Step 7
# Write EKSManager configuration to Parameter Store in shared services.
# -----------------------------------------------------------------------------
#
# Why every parameter here is String and not SecureString
# -------------------------------------------------------
# A Well-Architected review (August 2026) flagged these as a finding, on the
# reasonable prior that a bootstrap system's Parameter Store usually holds
# something sensitive. Reviewed parameter by parameter, none of these do.
#
# What is actually stored: the shared services and management account ids and
# their regions, the agent role ARN, the account StackSet name, two Identity
# Center permission set ARNs, the identity store id and its region, the
# Identity Center role ARN, a secrets-editing feature flag, the app URL, the
# Cognito client id and token endpoint, and the customer's cost-allocation tag
# name and value.
#
# Every one is configuration. Several are already public knowledge to anyone
# holding an ARN from this account. None is a credential, and none grants
# anything on its own -- an account id or a role ARN is an identifier, not a
# key. Access still has to be granted by IAM, which it is: read is scoped to
# /EKSManager/config/* and all writes are explicitly denied to the agent.
#
# The things that ARE secret are not here. The M2M client secret and the GitHub
# App private key live in Secrets Manager, encrypted with EKSManagerCMK, in
# iam/codebuild-pipeline-tf. That separation is the point: this module is where
# configuration goes precisely so that a reader can tell at a glance that it
# holds none.
#
# Converting these to SecureString would not be neutral. Every reader would
# then need kms:Decrypt, which means widening the agent's KMS grant and adding
# one to anything else that reads config, in exchange for encrypting values
# that are not secret. It would trade a real increase in permission surface for
# a nominal control.
#
# If a genuine secret ever needs to live in Parameter Store, use SecureString
# with EKSManagerCMK for that parameter -- and update this note, because its
# claim is that no such parameter exists.
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

resource "aws_ssm_parameter" "eks_user_view_permission_set_arn" {
  name  = "/EKSManager/config/eks-user-view-permission-set-arn"
  type  = "String"
  value = var.eks_manager_user_view_permission_set_arn
}

resource "aws_ssm_parameter" "eks_user_admin_permission_set_arn" {
  name  = "/EKSManager/config/eks-user-admin-permission-set-arn"
  type  = "String"
  value = var.eks_manager_user_admin_permission_set_arn
}

resource "aws_ssm_parameter" "identity_store_id" {
  name  = "/EKSManager/config/identity-store-id"
  type  = "String"
  value = var.identity_store_id
}

resource "aws_ssm_parameter" "identity_center_role_arn" {
  name  = "/EKSManager/config/identity-center-role-arn"
  type  = "String"
  value = var.eks_manager_identity_center_role_arn
}

resource "aws_ssm_parameter" "identity_center_region" {
  name  = "/EKSManager/config/identity-center-region"
  type  = "String"
  value = var.identity_center_resolved_region
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

# Read by the agent at cluster/node-group create time. Terraform's default_tags
# cannot reach those -- they are created by the agent through the AWS CLI, not
# by this module -- so the value is published here instead.
#
# Always written, even when empty: the agent treats an empty key as "no tag",
# and a missing parameter would have it guessing between "not configured" and
# "cannot read Parameter Store".
resource "aws_ssm_parameter" "resource_tag_name" {
  name  = "/EKSManager/config/resource-tag-name"
  type  = "String"
  value = var.resource_tag_name == "" ? "none" : var.resource_tag_name
}

resource "aws_ssm_parameter" "resource_tag_value" {
  name  = "/EKSManager/config/resource-tag-value"
  type  = "String"
  value = var.resource_tag_value == "" ? "none" : var.resource_tag_value
}
