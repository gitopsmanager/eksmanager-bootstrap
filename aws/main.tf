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
# Step 3 — Identity Center: Headlamp OIDC application
# -----------------------------------------------------------------------------
module "identity_center" {
  source = "./modules/identity_center"

  providers = {
    aws        = aws
    aws.shared = aws.shared
  }

  sso_instance_arn         = var.sso_instance_arn
  organization_id          = var.organization_id
  headlamp_redirect_domain = var.headlamp_redirect_domain
  app_url                  = var.app_url
}

# -----------------------------------------------------------------------------
# Step 4 — IAM roles in the management account
# -----------------------------------------------------------------------------
module "iam" {
  source = "./modules/iam"

  management_account_id      = var.management_account_id
  shared_services_account_id = var.shared_services_account_id
  headlamp_app_arn           = module.identity_center.headlamp_app_arn

  depends_on = [module.identity_center]
}

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
  management_account_id      = var.management_account_id
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
  headlamp_app_arn           = module.identity_center.headlamp_app_arn
  headlamp_role_arn          = module.iam.headlamp_role_arn
  agent_role_arn             = module.shared_services.agent_role_arn
  secrets_editing            = var.secrets_editing
  headlamp_oidc_secret_arn   = module.identity_center.headlamp_oidc_secret_arn
  app_url                    = var.app_url
  client_id                  = var.client_id
  cognito_url                = var.cognito_url

  depends_on = [module.shared_services, module.identity_center, module.iam]
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
