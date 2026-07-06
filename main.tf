# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

# ── AWS module ────────────────────────────────────────────────────────────────
module "aws" {
  source = "./aws"

  management_account_id      = var.management_account_id
  management_account_region  = var.management_account_region
  shared_services_account_id = var.shared_services_account_id
  shared_services_region     = var.shared_services_region
  secrets_editing            = var.secrets_editing
  org_config                 = var.org_config
  manage_scp_automatically   = var.manage_scp_automatically
  agent_name                 = var.agent_name
  agent_subnet_id            = var.agent_subnet_id
  agent_security_group_id    = var.agent_security_group_id
  agent_ami                  = var.agent_ami
  sso_instance_arn           = var.sso_instance_arn
  organization_id            = var.organization_id
  af7_bundle_download_url    = var.af7_bundle_download_url
  agent_upgrade_download_url = var.agent_upgrade_download_url
  agent_download_url         = var.agent_download_url
  agent_upload_url           = var.agent_upload_url
  app_url                    = var.app_url
  client_id                  = var.client_id
  cognito_url                = var.cognito_url
  bearer_token                = var.bearer_token
}

# ── Bootstrap status reporting ──────────────────────────────────────────────
# Reports "bootstrap completed" and polls until the agent connects. No config
# payload (zones/ArgoCD/GitHub apps) -- that's completed afterward via the
# EKS Manager GUI, not part of this public repo.

resource "terraform_data" "aws_bootstrap_status" {
  provisioner "local-exec" {
    command = <<-CMD
      curl -fsSL -X POST "${var.app_url}/config/aws/bootstrap-status" \
        -H "Authorization: Bearer ${var.bearer_token}" \
        -H "Content-Type: application/json" \
        -d '${jsonencode({
          sharedServicesAccountId     = var.shared_services_account_id
          sharedServicesAccountRegion = var.shared_services_region
          secretsManager              = true
          ecr                         = true
          headlamp                    = true
          agentRegistered             = false
        })}'
    CMD
  }

  depends_on = [module.aws]
}

# Polls every 15 seconds for up to 10 minutes. Server returns overall="ok"
# only once the agent for this license is connected.
data "http" "agent_status" {
  url    = "${var.app_url}/bootstrap/agent-status"
  method = "GET"

  request_headers = {
    Authorization = "Bearer ${var.bearer_token}"
  }

  retry {
    attempts     = 40
    min_delay_ms = 15000
    max_delay_ms = 15000
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 &&
                      jsondecode(self.response_body).overall == "ok"
      error_message = <<-EOT
        Agent not connected after 10 minutes.
        Status: ${self.response_body}
        Check EC2 instance user_data logs at /var/log/cloud-init-output.log
      EOT
    }
  }

  depends_on = [terraform_data.aws_bootstrap_status]
}
