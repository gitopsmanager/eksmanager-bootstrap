# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# eksmanager-prefix-lists-pipeline — main.tf
# -----------------------------------------------------------------------------
# Applied the same way as ../codebuild-pipeline-tf — pure Terraform, ambient
# credentials, aws.shared assumes shared_services_role_name into the shared
# services account to create everything here.
#
# Creates ONE CodeBuild project (eksmanager-prefix-lists) that runs two
# different kinds of build, distinguished by which S3 object triggered it:
#   - org-changes.zip  -> terraform/org-changes  (granular prefix lists,
#     rolled out to every enabled account/region — org-wide blast radius)
#   - add-cluster.zip  -> terraform/add-cluster   (SG rules for one cluster)
#
# Deliberately NOT auto-chained after eksmanager-bootstrap succeeds — an
# org-changes run is org-wide and replaces prefix lists in place
# (create_before_destroy), so running it is a separate, reviewed decision:
# trigger org-changes.yml manually (workflow_dispatch) once bootstrap's
# account/region changes look correct, not automatically the moment
# bootstrap's build reports SUCCEEDED.
#
# One project, one fixed CodeBuild "source" block — but its source.location
# is only ever used as a fallback for a manual console-triggered build.
# Every real invocation comes from EventBridge, which overrides the source
# per rule via input_transformer + sourceLocationOverride, so org-changes.zip
# and add-cluster.zip never race to overwrite the same object.
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

provider "aws" {
  alias  = "shared"
  region = var.shared_services_region

  assume_role {
    role_arn     = "arn:aws:iam::${var.shared_services_account_id}:role/${var.shared_services_role_name}"
    session_name = "eksmanager-prefix-lists-setup"
  }

  default_tags {
    tags = {
      ManagedBy = "EKSManager"
      Module    = "eksmanager-prefix-lists-pipeline"
    }
  }
}

locals {
  prefix_lists_bucket = "eksmanager-prefix-lists-${var.shared_services_account_id}"
}

# ── S3 bucket for prefix-lists / add-cluster release artifacts ─────────────

resource "aws_s3_bucket" "prefix_lists" {
  provider = aws.shared
  bucket   = local.prefix_lists_bucket
}

resource "aws_s3_bucket_versioning" "prefix_lists" {
  provider = aws.shared
  bucket   = aws_s3_bucket.prefix_lists.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "prefix_lists" {
  provider                = aws.shared
  bucket                  = aws_s3_bucket.prefix_lists.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── GitHub Actions OIDC — org-changes.yml and add-cluster.yml in the fork ──
# Reuses the OIDC provider iam/codebuild-pipeline-tf already created (or was
# pointed at) — not recreated here, an AWS account only gets one per URL.

resource "aws_iam_role" "github_actions_upload" {
  provider = aws.shared
  name     = "EKSManagerPrefixListsGithubActionsRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.github_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_upload" {
  provider = aws.shared
  name     = "EKSManagerPrefixListsGithubActionsUploadPolicy"
  role     = aws_iam_role.github_actions_upload.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "UploadPrefixListsArtifacts"
      Effect = "Allow"
      Action = "s3:PutObject"
      Resource = [
        "${aws_s3_bucket.prefix_lists.arn}/org-changes.zip",
        "${aws_s3_bucket.prefix_lists.arn}/add-cluster.zip"
      ]
    }]
  })
}

# ── EKSManagerPrefixListsSharedRole — CodeBuild service role ───────────────
# Assumes client_account_role_name (default EKSManagerAdminRole) into
# whichever client account a given build targets. Wildcarded across account
# IDs deliberately -- org-config.json's account list changes independently
# of this policy, so adding/removing a client account never needs a
# Terraform change here.

resource "aws_iam_role" "codebuild" {
  provider = aws.shared
  name     = "EKSManagerPrefixListsSharedRole"

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
  name     = "EKSManagerPrefixListsSharedRolePolicy"
  role     = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3PrefixListsArtifacts"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.prefix_lists.arn,
          "${aws_s3_bucket.prefix_lists.arn}/*"
        ]
      },
      {
        # Terraform S3 backend -- per-account/region state for org-changes,
        # per-cluster state for add-cluster (see terraform/*/backend
        # configs). Same bucket as the zip source, scoped to state/* only.
        Sid      = "TerraformStateBackend"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.prefix_lists.arn}/state/*"
      },
      {
        # M2M secret is the same one iam/codebuild-pipeline-tf created --
        # reused, not recreated, for add-cluster's success/failure callback.
        Sid      = "SecretsManagerM2M"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = "arn:aws:secretsmanager:*:${var.shared_services_account_id}:secret:/EKSManagerBootstrap/client-m2m-cognito-secret-??????"
      },
      {
        Sid      = "AssumeClientAccountRole"
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = "arn:aws:iam::*:role/${var.client_account_role_name}"
      },
      {
        # Lets CodeBuild create/manage the ENI used to reach the VPC. Same
        # requirement, same permissions as eksmanager-bootstrap's role --
        # this is CodeBuild's own service role attaching to the VPC, not
        # the client_account_role_name AssumeRole above (that one's scoped
        # to client accounts only and has nothing to do with VPC
        # networking in the shared services account).
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
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:${var.shared_services_account_id}:log-group:/aws/codebuild/*"
      }
    ]
  })
}

# ── Network isolation — same requirement as eksmanager-bootstrap, same
# reasoning: add-cluster's callback needs a known, allowlisted egress IP ────

resource "aws_security_group" "codebuild" {
  provider    = aws.shared
  name        = "eksmanager-prefix-lists-codebuild-sg"
  description = "Network perimeter for the EKS Manager prefix-lists CodeBuild container - no inbound, egress via VPC routing"
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
# VPC attachment required, same as eksmanager-bootstrap -- see the vpc_id
# variable's description for why.

resource "aws_codebuild_project" "eksmanager_prefix_lists" {
  provider      = aws.shared
  name          = "eksmanager-prefix-lists"
  description   = "Runs EKS Manager prefix-list (org-changes) and cluster SG-rule (add-cluster) Terraform"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 60

  artifacts {
    type = "NO_ARTIFACTS"
  }

  source {
    type      = "S3"
    location  = "${aws_s3_bucket.prefix_lists.bucket}/org-changes.zip"
    buildspec = "buildspec.yml"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

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
      group_name = "/aws/codebuild/eksmanager-prefix-lists"
    }
  }
}

# ── EventBridge -- one rule per artifact key, each overriding the project's
# source at start time so org-changes.zip and add-cluster.zip never race to
# overwrite a shared object ──────────────────────────────────────────────────

resource "aws_s3_bucket_notification" "eventbridge" {
  provider    = aws.shared
  bucket      = aws_s3_bucket.prefix_lists.id
  eventbridge = true
}

resource "aws_iam_role" "eventbridge_codebuild" {
  provider = aws.shared
  name     = "EKSManagerPrefixListsEventBridgeRole"

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
  name     = "EKSManagerPrefixListsEventBridgeStartBuild"
  role     = aws_iam_role.eventbridge_codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "codebuild:StartBuild"
      Resource = aws_codebuild_project.eksmanager_prefix_lists.arn
    }]
  })
}

resource "aws_cloudwatch_event_rule" "org_changes_uploaded" {
  provider = aws.shared
  name     = "eksmanager-prefix-lists-org-changes-uploaded"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [local.prefix_lists_bucket] }
      object = { key = ["org-changes.zip"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "start_org_changes" {
  provider = aws.shared
  rule     = aws_cloudwatch_event_rule.org_changes_uploaded.name
  arn      = aws_codebuild_project.eksmanager_prefix_lists.arn
  role_arn = aws_iam_role.eventbridge_codebuild.arn

  input_transformer {
    input_template = jsonencode({
      sourceLocationOverride = "${local.prefix_lists_bucket}/org-changes.zip"
    })
  }
}

resource "aws_cloudwatch_event_rule" "add_cluster_uploaded" {
  provider = aws.shared
  name     = "eksmanager-prefix-lists-add-cluster-uploaded"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [local.prefix_lists_bucket] }
      object = { key = ["add-cluster.zip"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "start_add_cluster" {
  provider = aws.shared
  rule     = aws_cloudwatch_event_rule.add_cluster_uploaded.name
  arn      = aws_codebuild_project.eksmanager_prefix_lists.arn
  role_arn = aws_iam_role.eventbridge_codebuild.arn

  input_transformer {
    input_template = jsonencode({
      sourceLocationOverride = "${local.prefix_lists_bucket}/add-cluster.zip"
    })
  }
}
