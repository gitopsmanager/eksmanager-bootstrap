# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# eksmanager-prefix-lists-pipeline — main.tf
# -----------------------------------------------------------------------------
# Applied the same way as ../codebuild-pipeline-tf — pure Terraform, ambient
# credentials, aws.shared assumes shared_services_role_name into the shared
# services account to create everything here.
#
# Creates ONE CodeBuild project (eksmanager-prefix-lists) which runs
# terraform/add-cluster -- the SG rules for a single cluster -- triggered by
# add-cluster.zip landing in the artifact bucket.
#
# The prefix lists themselves are NOT created or managed here. They are
# expected to already exist in each target account and region, and
# terraform/add-cluster resolves them by name.
#
# One project, one fixed CodeBuild "source" block -- but its source.location
# is only ever used as a fallback for a manual console-triggered build. Every
# real invocation comes from EventBridge, which overrides the source per rule
# via input_transformer + sourceLocationOverride.
# -----------------------------------------------------------------------------

terraform {
  # 1.10 for use_lockfile below -- S3-native state locking, no DynamoDB table.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }

  # Remote state, so this module is not owned by whichever laptop ran it first.
  # It used to be a local terraform.tfstate: a second operator running
  # setup-pipeline started from empty state, planned to create everything, and
  # died partway on the first name collision -- leaving two partial and
  # divergent views of one installation.
  #
  # bucket and region come from -backend-config at init; the script creates the
  # bucket with the AWS CLI beforehand. Deliberately NOT a Terraform resource:
  # this module creates the bootstrap bucket, so it cannot also keep its state
  # there, and a bucket declared in the module storing its own state is the
  # cycle this avoids.
  backend "s3" {
    key          = "setup/prefix-lists-pipeline/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
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
      "ManagedBy"   = "EKSManager"
      "Deployed By" = "GitOpsManager"
      "Managed By"  = "Terraform"
      "Environment" = "production"
      "Module"      = "eksmanager-prefix-lists-pipeline"
    }
  }
}

locals {
  prefix_lists_bucket = "eksmanager-prefix-lists-${var.shared_services_account_id}"
}

# EKSManagerCMK, created by iam/codebuild-pipeline-tf. setup-pipeline.sh applies
# that module before this one, so the alias resolves. Looked up rather than
# declared -- one key, one owner.
data "aws_kms_key" "eksmanager" {
  provider = aws.shared
  key_id   = "alias/EKSManagerCMK"
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

# Holds add-cluster.zip and, under accounts/<acct>/clusters/<cluster>/, the
# Terraform state for every cluster's security group rules. That state names
# security groups and prefix lists, so it is worth the same key as everything
# else rather than the account default it had.
#
# Existing objects keep whatever they were written with -- S3 does not
# re-encrypt in place. Both kinds here are rewritten on every run anyway: the
# zip on each dispatch, the state on each apply.
resource "aws_s3_bucket_server_side_encryption_configuration" "prefix_lists" {
  provider = aws.shared
  bucket   = aws_s3_bucket.prefix_lists.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = data.aws_kms_key.eksmanager.arn
    }
    bucket_key_enabled = true
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

# ── GitHub Actions OIDC — add-cluster.yml in your private copy ──────────────────────
# Reuses the OIDC provider iam/codebuild-pipeline-tf already created (or was
# pointed at) — not recreated here, an AWS account only gets one per URL.

locals {
  # See iam/codebuild-pipeline-tf/main.tf for the full rationale.
  github_sub_repo = (var.github_owner_id != "" && var.github_repo_id != "") ? (
    "${split("/", var.github_repo)[0]}@${var.github_owner_id}/${split("/", var.github_repo)[1]}@${var.github_repo_id}"
  ) : var.github_repo
}

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
          "token.actions.githubusercontent.com:sub" = "repo:${local.github_sub_repo}:ref:refs/heads/main"
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
    Statement = [
      {
        Sid      = "UploadPrefixListsArtifacts"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.prefix_lists.arn}/add-cluster.zip"
      },
      {
        # S3 asks KMS for a fresh data key on every write. A role holding only
        # Decrypt uploads nothing and fails as AccessDenied on the PUT, which
        # reads like a bucket policy fault rather than a KMS one.
        Sid      = "EKSManagerCMK"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
        Resource = data.aws_kms_key.eksmanager.arn
      },
    ]
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
        Sid    = "S3PrefixListsArtifacts"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.prefix_lists.arn,
          "${aws_s3_bucket.prefix_lists.arn}/*"
        ]
      },
      {
        # Terraform S3 backend -- add-cluster uses
        # accounts/<account>/clusters/<cluster>/terraform.tfstate.
        # Both live under accounts/*, NOT state/* -- that was
        # eksmanager-bootstrap's different, flat state/terraform.tfstate
        # key convention; copying its resource scope here without
        # updating it left this role unable to write its own lock file.
        # Includes the native S3 lock file (*.tflock, terraform >= 1.11's
        # use_lockfile) alongside the state file itself.
        Sid      = "TerraformStateBackend"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.prefix_lists.arn}/accounts/*"
      },
      {
        # This role both READS add-cluster.zip and READS/WRITES the per-cluster
        # Terraform state in the same bucket, so it needs a data key for the
        # writes as well as Decrypt for the reads.
        #
        # ViaService bounds it to S3: the role cannot decrypt anything with this
        # key by calling KMS directly. DescribeKey is deliberately absent -- S3
        # resolves the key itself, and nothing here does a Terraform-style alias
        # lookup at runtime.
        Sid      = "EKSManagerCMK"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = data.aws_kms_key.eksmanager.arn
        Condition = {
          StringEquals = {
            "kms:ViaService" = "s3.${var.shared_services_region}.amazonaws.com"
          }
        }
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

resource "aws_codebuild_project" "eksmanager_prefix_lists" {
  provider      = aws.shared
  name          = "eksmanager-prefix-lists"
  description   = "Runs EKS Manager cluster SG-rule (add-cluster) Terraform"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 60

  artifacts {
    type = "NO_ARTIFACTS"
  }

  source {
    type      = "S3"
    location  = "${aws_s3_bucket.prefix_lists.bucket}/add-cluster.zip"
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
# source at start time so each artifact drives its own build without
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
