# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# eksmanager-codebuild-pipeline — main.tf
# -----------------------------------------------------------------------------
# Applied by ../../setup-pipeline.sh (or .ps1) — pure Terraform, no manual
# role-assumption fallback. Run with ambient credentials already
# authenticated to the MANAGEMENT account:
#   - default provider creates EKSManagerBootstrap directly there
#   - aws.shared provider assumes shared_services_role_name (default
#     AWSControlTowerExecution — the role Control Tower's Account Factory
#     creates in every enrolled account; OrganizationAccountAccessRole if
#     the account was created via plain AWS Organizations instead) to
#     create everything else
#
# No try-list, no pause-for-manual-switch: if the assume_role fails,
# apply fails clearly on the first aws.shared-scoped resource. Fix is to
# set SHARED_SERVICES_ROLE_NAME to the correct role and re-run.
#
# Creates:
#   - EKSManagerBootstrap in the management account — scoped policy, not
#     AdministratorAccess (see policies/EKSManagerBootstrap-policy.json)
#   - EKSManagerBootstrapSharedRole — CodeBuild service role, scoped to
#     exactly what the AWS bootstrap Terraform module needs:
#       - cloudformation:*StackSet* on the EKSManagerEnableAccountStackSet
#         (usable directly via DELEGATED_ADMIN — no AssumeRole needed)
#       - organizations:List*/Describe* (read-only, to resolve OU/account
#         structure when deploying StackSet instances)
#       - Read-only S3 access to the bootstrap bucket (CodeBuild only reads
#         the release zip; it never writes to GitHub or S3)
#       - Secrets Manager read on the M2M client secret
#       - CloudWatch Logs for the CodeBuild project
#   - A CodeBuild project (S3-sourced — no GitHub credential involved)
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }
}

# Management account — ambient credentials, no assume_role. Whoever runs
# terraform apply must already be authenticated here.
provider "aws" {
  region = var.management_account_region

  default_tags {
    tags = {
      ManagedBy = "EKSManager"
      Module    = "eksmanager-codebuild-pipeline"
    }
  }
}

# Shared services account — single static assume_role, no try-list.
provider "aws" {
  alias  = "shared"
  region = var.shared_services_region

  assume_role {
    role_arn     = "arn:aws:iam::${var.shared_services_account_id}:role/${var.shared_services_role_name}"
    session_name = "eksmanager-bootstrap-setup"
  }

  default_tags {
    tags = {
      ManagedBy = "EKSManager"
      Module    = "eksmanager-codebuild-pipeline"
    }
  }
}

# Verifies the ambient credentials are actually the management account —
# there's no role-ARN construction to self-verify this one, unlike the
# shared services side below.
data "aws_caller_identity" "management" {}

locals {
  assert_management_account = (
    data.aws_caller_identity.management.account_id == var.management_account_id
    ? true
    : tobool("ERROR: Terraform runner is authenticated to account ${data.aws_caller_identity.management.account_id} but management_account_id is ${var.management_account_id}. Authenticate to the management account before running.")
  )

  bootstrap_bucket = "eksmanager-bootstrap-${var.shared_services_account_id}"
}

# ── EKSManagerBootstrap — management account ────────────────────────────────
# Scoped to exactly what this module needs there — not AdministratorAccess.
# Trusts the shared services account root; EKSManagerBootstrapSharedRole
# (below) is the one that actually calls sts:AssumeRole on it — see its
# own policy for the matching grant.

resource "aws_iam_role" "management_bootstrap" {
  name = "EKSManagerBootstrap"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.shared_services_account_id}:root" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "management_bootstrap" {
  name   = "EKSManagerBootstrapPolicy"
  role   = aws_iam_role.management_bootstrap.id
  policy = file("${path.module}/policies/EKSManagerBootstrap-policy.json")
}

# ── S3 bucket for bootstrap release artifacts ───────────────────────────────
# Terraform-owned — setup-pipeline.sh/.ps1 only sets up infrastructure, it
# doesn't clone, zip, or upload anything, so there's no ordering conflict
# with something else creating this bucket first.

resource "aws_s3_bucket" "bootstrap" {
  provider = aws.shared
  bucket   = local.bootstrap_bucket
}

resource "aws_s3_bucket_versioning" "bootstrap" {
  provider = aws.shared
  bucket   = aws_s3_bucket.bootstrap.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "bootstrap" {
  provider                = aws.shared
  bucket                  = aws_s3_bucket.bootstrap.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── M2M client secret ─────────────────────────────────────────────────────────
# Read by the buildspec at build time via the secrets-manager block. Value is
# passed in as a Terraform variable (sensitive, never written to state in
# plaintext logs) rather than typed directly into the AWS console or CLI
# history.

resource "aws_secretsmanager_secret" "eksmanager_client_secret" {
  provider    = aws.shared
  name        = "/EKSManagerBootstrap/client-m2m-cognito-secret"
  description = "M2M client secret for the EKS Manager bootstrap pipeline"
}

resource "aws_secretsmanager_secret_version" "eksmanager_client_secret" {
  provider      = aws.shared
  secret_id     = aws_secretsmanager_secret.eksmanager_client_secret.id
  secret_string = var.eksmanager_client_secret
}

# ── GitHub App credentials ──────────────────────────────────────────────────
# setup-pipeline.sh/.ps1 doesn't clone anything itself — it just passes
# these straight through to Terraform to persist here, so whatever later
# clones the fork and uploads eksmanager-bootstrap.zip to S3 has a
# credential to use. Stored as one JSON secret; privateKey is base64,
# matching the GITHUB_APP_PRIVATE_KEY env var format.
# CodeBuild's own role is NOT granted access to this secret — CodeBuild never
# touches GitHub in this design. Any future automation's role would need
# secretsmanager:GetSecretValue on this secret's ARN added explicitly.

resource "aws_secretsmanager_secret" "github_app" {
  provider    = aws.shared
  name        = "/EKSManagerBootstrap/github-app"
  description = "GitHub App credentials (appId, installId, base64 privateKey) used to clone the eksmanager-bootstrap fork"
}

resource "aws_secretsmanager_secret_version" "github_app" {
  provider  = aws.shared
  secret_id = aws_secretsmanager_secret.github_app.id
  secret_string = jsonencode({
    appId      = var.github_app_id
    installId  = var.github_app_install_id
    privateKey = var.github_app_private_key
  })
}

# ── GitHub Actions OIDC — .github/workflows/upload-to-s3.yml in the fork ────
# Coexists with the persisted GitHub App credentials above (two independent
# ways to get eksmanager-bootstrap.zip into S3, not a replacement for
# either). No long-lived secret: GitHub mints a short-lived token per
# workflow run, trusted directly by this role.
#
# token.actions.githubusercontent.com is an account-wide singleton — an AWS
# account can only have ONE OIDC provider per URL. Rather than detecting
# this at apply time, it's an explicit opt-in: if the shared services
# account doesn't already have one, leave github_oidc_provider_arn empty
# and Terraform creates it. If it does, apply will fail once with
# EntityAlreadyExists — nothing gets written to state on a failed create,
# so there's nothing to clean up. Just set github_oidc_provider_arn to the
# existing provider's ARN
# (arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com)
# and re-run. Idempotent either way.

resource "aws_iam_openid_connect_provider" "github_actions" {
  provider        = aws.shared
  count           = var.github_oidc_provider_arn == "" ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

locals {
  github_oidc_provider_final_arn = var.github_oidc_provider_arn != "" ? var.github_oidc_provider_arn : aws_iam_openid_connect_provider.github_actions[0].arn
}

resource "aws_iam_role" "github_actions_upload" {
  provider = aws.shared
  name     = "EKSManagerBootstrapGithubActionsRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_provider_final_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # workflow_dispatch sub claim format: repo:<owner>/<repo>:ref:refs/heads/<branch>
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_upload" {
  provider = aws.shared
  name     = "EKSManagerBootstrapGithubActionsUploadPolicy"
  role     = aws_iam_role.github_actions_upload.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "UploadBootstrapZip"
      Effect   = "Allow"
      Action   = "s3:PutObject"
      Resource = "${aws_s3_bucket.bootstrap.arn}/eksmanager-bootstrap.zip"
    }]
  })
}

# ── EKSManagerBootstrapSharedRole — CodeBuild service role ──────────────────

resource "aws_iam_role" "codebuild" {
  provider = aws.shared
  name     = "EKSManagerBootstrapSharedRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  provider = aws.shared
  name     = "EKSManagerBootstrapSharedRolePolicy"
  role     = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3Bootstrap"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.bootstrap.arn,
          "${aws_s3_bucket.bootstrap.arn}/*"
        ]
      },
      {
        Sid      = "SecretsManager"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = [aws_secretsmanager_secret.eksmanager_client_secret.arn]
      },
      {
        # Lets the root aws/ Terraform module's default provider assume
        # EKSManagerBootstrap in the management account, so the org/
        # identity_center/iam/scp submodules actually run there instead of
        # against this (shared services) account.
        Sid      = "AssumeManagementAccountBootstrapRole"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.management_bootstrap.arn
      },
      {
        # Lets the root aws/ Terraform module's aws.shared provider assume
        # an elevated role WITHIN this same (shared services) account --
        # EKSManagerBootstrapSharedRole itself is deliberately narrow (see
        # header comment), so provisioning the actual bootstrap
        # infrastructure (agent EC2, ECR, Secrets Manager writes, etc.)
        # needs this explicit elevation, same reasoning as the
        # management-account grant above. buildspec.yml resolves at
        # runtime which of these two actually exists in the account and
        # writes it to role-override.auto.tfvars.json.
        Sid    = "AssumeSharedServicesElevatedRole"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Resource = [
          "arn:aws:iam::${var.shared_services_account_id}:role/AWSControlTowerExecution",
          "arn:aws:iam::${var.shared_services_account_id}:role/OrganizationAccountAccessRole"
        ]
      },
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:${var.shared_services_account_id}:log-group:/aws/codebuild/*"
      },
      {
        # StackSet operations run as DELEGATED_ADMIN — scoped to the single
        # StackSet the AWS bootstrap module creates and manages.
        Sid    = "DelegatedStackSetOperations"
        Effect = "Allow"
        Action = [
          "cloudformation:CreateStackSet",
          "cloudformation:UpdateStackSet",
          "cloudformation:DeleteStackSet",
          "cloudformation:DescribeStackSet",
          "cloudformation:DescribeStackSetOperation",
          "cloudformation:ListStackSetOperations",
          "cloudformation:ListStackInstances",
          "cloudformation:CreateStackInstances",
          "cloudformation:UpdateStackInstances",
          "cloudformation:DeleteStackInstances",
          "cloudformation:DescribeStackInstance"
        ]
        Resource = "arn:aws:cloudformation:*:*:stackset/EKSManagerEnableAccountStackSet:*"
      },
      {
        # ListStackSets does not support resource-level scoping.
        Sid      = "ListStackSets"
        Effect   = "Allow"
        Action   = "cloudformation:ListStackSets"
        Resource = "*"
      },
      {
        # Read-only — needed to resolve OU and account structure when
        # deploying StackSet instances. No write/mutate permissions.
        Sid    = "OrganizationsReadOnly"
        Effect = "Allow"
        Action = [
          "organizations:DescribeOrganization",
          "organizations:ListRoots",
          "organizations:ListOrganizationalUnitsForParent",
          "organizations:ListAccountsForParent",
          "organizations:ListDelegatedAdministrators",
          "organizations:DescribeAccount"
        ]
        Resource = "*"
      },
      {
        # Required so CloudFormation can create the StackSet's own
        # service-linked role on first use.
        Sid      = "PassRoleForStackSets"
        Effect   = "Allow"
        Action   = "iam:CreateServiceLinkedRole"
        Resource = "arn:aws:iam::*:role/aws-service-role/stacksets.cloudformation.amazonaws.com/*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "stacksets.cloudformation.amazonaws.com"
          }
        }
      },
      {
        # Lets CodeBuild create/manage the ENI used to reach the VPC.
        Sid    = "AllowVPCAttachment"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeDhcpOptions",
          "ec2:DescribeVpcs"
        ]
        Resource = "*"
      },
      {
        Sid      = "AllowVPCNetworkInterfacePermission"
        Effect   = "Allow"
        Action   = "ec2:CreateNetworkInterfacePermission"
        Resource = "arn:aws:ec2:*:${var.shared_services_account_id}:network-interface/*"
        Condition = {
          StringEquals = {
            "ec2:AuthorizedService" = "codebuild.amazonaws.com"
          }
        }
      },
      {
        # Public parameters published by Canonical/AWS — no account ID in
        # the ARN. Used by buildspec.yml to resolve the current Ubuntu
        # 22.04 AMI for the agent VM at build time, per shared services
        # region.
        Sid      = "PublicAmiLookup"
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:*::parameter/aws/service/canonical/ubuntu/*"
      }
    ]
  })
}

# ── Network isolation (required) ─────────────────────────────────────────────
# The CodeBuild container runs inside the client's VPC with no inbound access.
# Egress goes via the VPC's NAT Gateway, whose Elastic IP must be the address
# allowlisted on the client's API/GitHub/AWS endpoint firewalls — this is why
# vpc_id and vpc_subnet_id are required, not optional. AWS-managed networking
# would give CodeBuild a different, unpredictable IP on every run.

resource "aws_security_group" "codebuild" {
  provider    = aws.shared
  name        = "eksmanager-bootstrap-codebuild-sg"
  description = "Network perimeter for the EKS Manager bootstrap CodeBuild container - no inbound, egress via VPC routing"
  vpc_id      = var.vpc_id

  egress {
    description = "All outbound - restrict further via VPC route tables / NACLs if needed"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "agent" {
  provider    = aws.shared
  name        = "eksmanager-bootstrap-agent-sg"
  description = "EKS Manager agent VM - no inbound, egress only. Agent polls out; nothing connects in."
  vpc_id      = var.vpc_id

  egress {
    description = "All outbound - restrict further via VPC route tables / NACLs if needed"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ── CodeBuild project ────────────────────────────────────────────────────────
# Sourced from S3 — never touches GitHub. setup-pipeline.sh/.ps1 only sets
# up this infrastructure; it doesn't clone the fork or upload anything
# here. Whatever later uploads eksmanager-bootstrap.zip can use the GitHub
# App credentials persisted in Secrets Manager (below) to do that clone.

resource "aws_codebuild_project" "eksmanager_bootstrap" {
  provider      = aws.shared
  name          = "eksmanager-bootstrap"
  description   = "Runs the EKS Manager AWS bootstrap Terraform module"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 60

  artifacts {
    type = "NO_ARTIFACTS"
  }

  source {
    type      = "S3"
    location  = "${aws_s3_bucket.bootstrap.bucket}/eksmanager-bootstrap.zip"
    buildspec = "buildspec.yml"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "APPROVED_VERSION"
      value = var.approved_version
    }
    environment_variable {
      name  = "EKSMANAGER_CLIENT_ID"
      value = var.eksmanager_client_id
    }
    environment_variable {
      name  = "EKSMANAGER_COGNITO_URL"
      value = var.eksmanager_cognito_url
    }
    environment_variable {
      name  = "EKSMANAGER_API_URL"
      value = var.eksmanager_api_url
    }
  }

  vpc_config {
    vpc_id             = var.vpc_id
    subnets            = [var.vpc_subnet_id]
    security_group_ids = [aws_security_group.codebuild.id]
  }

  logs_config {
    cloudwatch_logs {
      group_name = "/aws/codebuild/eksmanager-bootstrap"
    }
  }
}

# ── EventBridge trigger — starts a build when eksmanager-bootstrap.zip is
# uploaded to the bucket ────────────────────────────────────────────────────
# Covers both setup-pipeline.sh/.ps1's own upload and any future automation
# that re-clones and re-uploads. The build still pauses at the
# APPROVED_VERSION gate in buildspec.yml — this only starts it, it doesn't
# bypass approval.

resource "aws_s3_bucket_notification" "eventbridge" {
  provider    = aws.shared
  bucket      = aws_s3_bucket.bootstrap.id
  eventbridge = true
}

resource "aws_iam_role" "eventbridge_codebuild" {
  provider = aws.shared
  name     = "EKSManagerBootstrapEventBridgeRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_codebuild" {
  provider = aws.shared
  name     = "EKSManagerBootstrapEventBridgeStartBuild"
  role     = aws_iam_role.eventbridge_codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "codebuild:StartBuild"
      Resource = aws_codebuild_project.eksmanager_bootstrap.arn
    }]
  })
}

resource "aws_cloudwatch_event_rule" "bootstrap_zip_uploaded" {
  provider = aws.shared
  name     = "eksmanager-bootstrap-zip-uploaded"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [local.bootstrap_bucket] }
      object = { key = ["eksmanager-bootstrap.zip"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "start_codebuild" {
  provider = aws.shared
  rule     = aws_cloudwatch_event_rule.bootstrap_zip_uploaded.name
  arn      = aws_codebuild_project.eksmanager_bootstrap.arn
  role_arn = aws_iam_role.eventbridge_codebuild.arn
}
