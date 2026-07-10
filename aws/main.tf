# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform-aws-eksmanager — main.tf
# -----------------------------------------------------------------------------
# Wires all submodules in dependency order.
# Each module maps to one logical step of the bootstrap.
# -----------------------------------------------------------------------------

# Verify the runner is authenticated to the correct management account.
data "aws_caller_identity" "management" {}

locals {
  assert_management_account = (
    data.aws_caller_identity.management.account_id == var.management_account_id
    ? true
    : tobool("ERROR: Terraform runner is authenticated to account ${data.aws_caller_identity.management.account_id} but management_account_id is ${var.management_account_id}. Authenticate to the management account before running.")
  )
}

# -----------------------------------------------------------------------------
# Step 1 + 2 — Organizations: trusted access + delegated StackSet admin
# -----------------------------------------------------------------------------
module "org" {
  source = "./modules/org"

  shared_services_account_id = var.shared_services_account_id
}

# -----------------------------------------------------------------------------
# Step 3 — Headlamp login
# -----------------------------------------------------------------------------
# module "identity_center" removed. It registered Headlamp as an OIDC app
# against AWS IAM Identity Center (sso_instance_arn/organization_id), giving
# every AWS-hosted cluster's Headlamp login its own AWS-native identity
# mechanism, separate from the Cognito+Entra SAML federation already used
# for M2M auth and for Azure's Headlamp login.
#
# TODO: replace with Cognito as the OIDC provider Headlamp authenticates
# against, with Cognito terminating Entra SAML federation -- same mechanism
# already built (but not yet tested) for Azure. This makes AWS and Azure
# Headlamp login identical, and consolidates onto the Cognito User Pool
# already used for M2M auth and for the ALB-level auth already protecting
# these AWS clients. Needs: a Cognito App Client for Headlamp's
# authorization-code/human-login flow (distinct from the M2M client), and
# the Entra SAML "groups" assertion mapped into a Cognito-exposed OIDC
# "groups" claim for Kubernetes RBAC. See aws/modules/identity_center for
# the previous mechanism's shape (OIDC scopes, redirect URI, groups claim)
# as a reference for what the Cognito App Client needs to replicate.
#
# The module's source is left in aws/modules/identity_center/ for reference,
# just no longer called here.

# -----------------------------------------------------------------------------
# Step 5 — Shared services: ECR, Secrets Manager, S3, IAM roles
# -----------------------------------------------------------------------------
module "shared_services" {
  source = "./modules/shared_services"

  providers = {
    aws = aws.shared
  }

  shared_services_account_id = var.shared_services_account_id
  shared_services_region     = var.shared_services_region
  config_bucket_name         = local.config_bucket_name
  secrets_editing            = var.secrets_editing
}


# -----------------------------------------------------------------------------
# Step 7 — SSM Parameter Store: configuration in shared services
# -----------------------------------------------------------------------------
module "ssm" {
  source = "./modules/ssm"

  providers = {
    aws = aws.shared
  }

  shared_services_account_id = var.shared_services_account_id
  shared_services_region     = var.shared_services_region
  management_account_id      = var.management_account_id
  management_account_region  = var.management_account_region
  agent_role_arn             = module.shared_services.agent_role_arn
  secrets_editing            = var.secrets_editing
  app_url                    = var.app_url
  client_id                  = var.client_id
  cognito_url                = var.cognito_url

  depends_on = [module.shared_services]
}

# -----------------------------------------------------------------------------
# Step 8 — CloudFormation StackSet skeleton (registered from shared services
#           as delegated admin)
# -----------------------------------------------------------------------------
module "stackset" {
  source = "./modules/stackset"

  providers = {
    aws = aws.shared
  }

  shared_services_account_id = var.shared_services_account_id
  all_regions                = local.all_regions
  account_ou_map             = local.account_ou_map

  depends_on = [module.org]
}

module "scp" {
  source = "./modules/scp"
  count  = var.manage_scp_automatically ? 1 : 0

  shared_services_account_id = var.shared_services_account_id
  ou_ids                     = local.ou_ids

  depends_on = [module.org]
}

# -----------------------------------------------------------------------------
# Step 11 — Agent VM in shared services
# -----------------------------------------------------------------------------
module "agent" {
  source = "./modules/agent"

  providers = {
    aws = aws.shared
  }

  agent_name              = var.agent_name
  agent_instance_type     = var.agent_instance_type
  agent_ami               = var.agent_ami
  agent_subnet_id         = var.agent_subnet_id
  agent_role_name         = module.shared_services.agent_role_name
  af7_bundle_download_url = var.af7_bundle_download_url
  agent_upgrade_download_url = var.agent_upgrade_download_url
  agent_download_url      = var.agent_download_url
  agent_upload_url        = var.agent_upload_url

  depends_on = [module.shared_services]
}
