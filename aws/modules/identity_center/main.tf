# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# modules/identity_center — Step 3
# Registers the Headlamp OIDC application in AWS IAM Identity Center.
#
# What bootstrap owns (fixed, set once):
#   - Application definition
#   - Authentication method (IAM)
#   - Authorization code grant with wildcard redirect URI
#   - Attribute mappings: sub, email, name, groups
#   - Scopes: openid, profile, email, groups
#   - Kubernetes Secret JSON in Secrets Manager
#
# What your app owns at runtime (per cluster):
#   - Identity Center group assignments (PutApplicationAssignment)
#   - Kubernetes RBAC ClusterRoleBindings applied by the agent
#
# Groups limit: 100 per application (AWS hard limit, cannot be increased).
# Redirect URI: wildcard *.var.headlamp_redirect_domain — client must ensure
# subdomains are on a private network unreachable from the public internet.
# -----------------------------------------------------------------------------

data "aws_ssoadmin_instances" "current" {}

locals {
  # Derive the Identity Center issuer URL from the instance ARN.
  # Format: https://identitycenter.amazonaws.com/ssoins-xxxxxxxxxx
  instance_id = replace(
    tolist(data.aws_ssoadmin_instances.current.arns)[0],
    "arn:aws:sso:::instance/",
    ""
  )
  issuer_url = "https://identitycenter.amazonaws.com/${local.instance_id}"
}

# --- Headlamp OIDC application -----------------------------------------------

resource "aws_ssoadmin_application" "headlamp" {
  name                     = "EKSManager-Headlamp"
  description              = "Headlamp Kubernetes UI — OIDC provider for EKS Manager clusters"
  application_provider_arn = "arn:aws:sso::aws:applicationProvider/custom"
  instance_arn             = var.sso_instance_arn
  status                   = "ENABLED"

  portal_options {
    visibility = "DISABLED"
  }
}

# --- Authentication method ---------------------------------------------------
# Allows any authenticated Identity Center user to initiate sign-in.
# Group-based access control is enforced by Kubernetes RBAC, not here —
# the groups claim in the token determines what the user can do per cluster.

resource "aws_ssoadmin_application_authentication_method" "headlamp" {
  application_arn            = aws_ssoadmin_application.headlamp.application_arn
  authentication_method_type = "IAM"

  authentication_method {
    iam {
      actor_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Effect    = "Allow"
          Principal = { AWS = "*" }
          Action    = "sso:CreateTokenWithIAM"
          Condition = {
            StringEquals = {
              "aws:PrincipalOrgID" = var.organization_id
            }
          }
        }]
      })
    }
  }
}

# --- Authorization code grant with wildcard redirect URI ---------------------

resource "aws_ssoadmin_application_grant" "headlamp_authz_code" {
  application_arn = aws_ssoadmin_application.headlamp.application_arn
  grant_type      = "authorization_code"

  grant {
    authorization_code {
      redirect_uris = [
        "https://*.${var.headlamp_redirect_domain}/oidc-callback"
      ]
    }
  }
}

# --- Attribute mappings ------------------------------------------------------
# Maps Identity Center user attributes and group memberships into OIDC token.
# The groups claim is what Headlamp uses for Kubernetes RBAC binding.

resource "aws_ssoadmin_application_access_scope" "openid" {
  application_arn    = aws_ssoadmin_application.headlamp.application_arn
  scope              = "openid"
  authorized_targets = []
}

resource "aws_ssoadmin_application_access_scope" "profile" {
  application_arn    = aws_ssoadmin_application.headlamp.application_arn
  scope              = "profile"
  authorized_targets = []
}

resource "aws_ssoadmin_application_access_scope" "email" {
  application_arn    = aws_ssoadmin_application.headlamp.application_arn
  scope              = "email"
  authorized_targets = []
}

resource "aws_ssoadmin_application_access_scope" "groups" {
  application_arn    = aws_ssoadmin_application.headlamp.application_arn
  scope              = "groups"
  authorized_targets = []
}

# --- Secrets Manager: Kubernetes secret JSON ---------------------------------
# Created in the shared services account — EKSManagerAgentRole's
# secretsmanager permissions are scoped there, not the management account.

resource "aws_secretsmanager_secret" "headlamp_oidc" {
  provider    = aws.shared
  name        = "/EKSManager/headlamp/oidc-config"
  description = "Headlamp OIDC configuration — Kubernetes Secret JSON applied by the agent"
}

resource "aws_secretsmanager_secret_version" "headlamp_oidc" {
  provider  = aws.shared
  secret_id = aws_secretsmanager_secret.headlamp_oidc.id

  secret_string = jsonencode({
    apiVersion = "v1"
    kind       = "Secret"
    type       = "Opaque"
    metadata = {
      name      = "headlamp-oidc"
      namespace = "headlamp"
    }
    # Values are base64 encoded as required by Kubernetes Opaque secrets.
    # The agent applies this manifest directly via kubectl apply.
    stringData = {
      clientID   = aws_ssoadmin_application.headlamp.application_arn
      issuerURL  = local.issuer_url
      scopes     = "openid,profile,email,groups"
      groupsClaim = "groups"
    }
  })
}
