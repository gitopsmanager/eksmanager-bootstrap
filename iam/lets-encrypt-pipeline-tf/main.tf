# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# eksmanager-lets-encrypt-pipeline — main.tf
# -----------------------------------------------------------------------------
# Applied the same way as ../codebuild-pipeline-tf and ../prefix-lists-pipeline-tf
# — pure Terraform, ambient credentials, aws.shared assumes
# shared_services_role_name into the shared services account.
#
# Creates ONE CodeBuild project (eksmanager-lets-encrypt) which runs
# terraform/lets-encrypt: a wildcard certificate per hosted zone, stored in
# Secrets Manager. Two triggers, same apply:
#   - lets-encrypt.zip landing in the bucket  -> code or zone list changed
#   - a weekly EventBridge schedule           -> renew anything due
#
# The certificates live in their OWN Terraform state, not the bootstrap state.
# A schedule that runs unattended can change anything it can reach, so its
# reach is deliberately limited to certificates and their secrets.
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
    session_name = "eksmanager-lets-encrypt-setup"
  }

  default_tags {
    tags = {
      ManagedBy = "EKSManager"
      Module    = "eksmanager-lets-encrypt-pipeline"
    }
  }
}

locals {
  lets_encrypt_bucket = "eksmanager-lets-encrypt-${var.shared_services_account_id}"
  artifact_key        = "lets-encrypt.zip"

  # Terraform state for terraform/lets-encrypt, kept in this module's own
  # bucket under a fixed key. Same bucket as the artifact, different prefix --
  # matching how add-cluster keeps its state under accounts/ in the
  # prefix-lists bucket.
  state_key = "state/lets-encrypt.tfstate"

  # roles.cert_manager from private-hosted-zones.json. Every ARN listed becomes
  # assumable by EKSManagerLetsEncryptRole and nothing else is. If the file is
  # absent or has no zones yet, the list is empty and the AssumeRole statement
  # is omitted entirely rather than falling back to a wildcard.
  hosted_zones = try(
    jsondecode(file("${path.module}/${var.hosted_zones_file}"))["hosted-zones"],
    []
  )

  cert_manager_role_arns = distinct([
    for z in local.hosted_zones : z.roles.cert_manager
    if try(z.roles.cert_manager, "") != ""
  ])
}

# ── S3 bucket for the lets-encrypt artifact and Terraform state ──────────────

resource "aws_s3_bucket" "lets_encrypt" {
  provider = aws.shared
  bucket   = local.lets_encrypt_bucket
}

resource "aws_s3_bucket_versioning" "lets_encrypt" {
  provider = aws.shared
  bucket   = aws_s3_bucket.lets_encrypt.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "lets_encrypt" {
  provider                = aws.shared
  bucket                  = aws_s3_bucket.lets_encrypt.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Terraform state here holds every wildcard's PRIVATE KEY -- the acme provider
# stores certificate material in state, there is no way to avoid it. Encryption
# is therefore not optional hygiene; anyone who can read this bucket holds the
# keys for every zone.
resource "aws_s3_bucket_server_side_encryption_configuration" "lets_encrypt" {
  provider = aws.shared
  bucket   = aws_s3_bucket.lets_encrypt.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_notification" "eventbridge" {
  provider    = aws.shared
  bucket      = aws_s3_bucket.lets_encrypt.id
  eventbridge = true
}

# ── GitHub Actions OIDC upload role ──────────────────────────────────────────
# Same shape as the other two pipelines: the workflow assumes this to put the
# artifact in S3, which is what starts a build. Write-only, to one key.

resource "aws_iam_role" "github_actions_upload" {
  provider = aws.shared
  name     = "EKSManagerLetsEncryptGithubActionsRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.github_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = merge(
          { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" },
          var.github_owner_id != "" ? { "token.actions.githubusercontent.com:owner_id" = var.github_owner_id } : {},
          var.github_repo_id != "" ? { "token.actions.githubusercontent.com:repository_id" = var.github_repo_id } : {},
        )
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_upload" {
  provider = aws.shared
  name     = "EKSManagerLetsEncryptGithubActionsUploadPolicy"
  role     = aws_iam_role.github_actions_upload.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = "${aws_s3_bucket.lets_encrypt.arn}/${local.artifact_key}"
    }]
  })
}

# ── CodeBuild service role ───────────────────────────────────────────────────
# Its own identity, not the agent's and not the bootstrap pipeline's. Each
# pipeline having a distinct role is what lets CloudTrail say which one acted.

resource "aws_iam_role" "codebuild" {
  provider = aws.shared
  name     = "EKSManagerLetsEncryptRole"

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
  name     = "EKSManagerLetsEncryptRolePolicy"
  role     = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid    = "Logs"
          Effect = "Allow"
          Action = [
            "logs:CreateLogGroup",
            "logs:CreateLogStream",
            "logs:PutLogEvents",
          ]
          Resource = "arn:aws:logs:${var.shared_services_region}:${var.shared_services_account_id}:log-group:/aws/codebuild/eksmanager-lets-encrypt*"
        },
        {
          Sid      = "ArtifactAndState"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket"]
          Resource = [aws_s3_bucket.lets_encrypt.arn, "${aws_s3_bucket.lets_encrypt.arn}/*"]
        },
        {
          # Terraform S3 backend. use_lockfile writes a .tflock alongside the
          # state, so Put and Delete are both needed on that prefix.
          Sid    = "TerraformState"
          Effect = "Allow"
          Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          Resource = [
            "${aws_s3_bucket.lets_encrypt.arn}/${local.state_key}",
            "${aws_s3_bucket.lets_encrypt.arn}/${local.state_key}.tflock",
          ]
        },
        {
          # The certificates. Scoped by name prefix so this role cannot read
          # unrelated secrets in the shared services account -- notably the
          # bootstrap module's client-m2m-cognito-secret and github-app.
          Sid    = "CertificateSecrets"
          Effect = "Allow"
          Action = [
            "secretsmanager:CreateSecret",
            "secretsmanager:DescribeSecret",
            "secretsmanager:GetSecretValue",
            "secretsmanager:PutSecretValue",
            "secretsmanager:TagResource",
            "secretsmanager:UpdateSecret",
            "secretsmanager:ListSecretVersionIds",
          ]
          Resource = "arn:aws:secretsmanager:${var.shared_services_region}:${var.shared_services_account_id}:secret:dns-zone-certs-*"
        },
        {
          # ListSecrets has no resource-level scoping in IAM; Terraform needs it
          # to refresh. Read-only over names, no values.
          Sid      = "SecretsDiscovery"
          Effect   = "Allow"
          Action   = ["secretsmanager:ListSecrets"]
          Resource = "*"
        },
        {
          Sid    = "VpcNetworkInterfaces"
          Effect = "Allow"
          Action = [
            "ec2:CreateNetworkInterface",
            "ec2:DescribeNetworkInterfaces",
            "ec2:DeleteNetworkInterface",
            "ec2:DescribeSubnets",
            "ec2:DescribeSecurityGroups",
            "ec2:DescribeDhcpOptions",
            "ec2:DescribeVpcs",
          ]
          Resource = "*"
        },
        {
          Sid       = "VpcNetworkInterfacePermission"
          Effect    = "Allow"
          Action    = ["ec2:CreateNetworkInterfacePermission"]
          Resource  = "arn:aws:ec2:${var.shared_services_region}:${var.shared_services_account_id}:network-interface/*"
          Condition = { StringEquals = { "ec2:Subnet" = "arn:aws:ec2:${var.shared_services_region}:${var.shared_services_account_id}:subnet/${var.vpc_subnet_id}" } }
        },
      ],
      # Enumerated from private-hosted-zones.json rather than wildcarded. With
      # no zones configured this statement is absent entirely, so the role
      # starts with no cross-account reach at all.
      length(local.cert_manager_role_arns) > 0 ? [{
        Sid      = "AssumeCertManagerRoles"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = local.cert_manager_role_arns
      }] : []
    )
  })
}

resource "aws_security_group" "codebuild" {
  provider = aws.shared
  name     = "eksmanager-lets-encrypt-codebuild-sg"
  # Same charset restriction as the rule description below -- no apostrophe.
  # The provider only validates the rule one locally, so this would pass
  # `terraform validate` and fail at apply.
  description = "Egress-only for the EKS Manager ACME certificate CodeBuild project"
  vpc_id      = var.vpc_id

  egress {
    # No apostrophe: AWS rejects security group rule descriptions outside
    # ^[0-9A-Za-z_ .:/()#,@\[\]+=&;{}!$*-]*$ and an apostrophe is not in it.
    description = "Outbound HTTPS to ACME, Route53, Secrets Manager and the Terraform download"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_codebuild_project" "lets_encrypt" {
  provider      = aws.shared
  name          = "eksmanager-lets-encrypt"
  description   = "Issues and renews Let's Encrypt wildcard certificates per hosted zone"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 60

  artifacts {
    type = "NO_ARTIFACTS"
  }

  source {
    type      = "S3"
    location  = "${aws_s3_bucket.lets_encrypt.bucket}/${local.artifact_key}"
    buildspec = "buildspec.yml"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "STATE_BUCKET"
      value = local.lets_encrypt_bucket
    }
    environment_variable {
      name  = "STATE_KEY"
      value = local.state_key
    }
    environment_variable {
      name  = "TF_VAR_shared_services_region"
      value = var.shared_services_region
    }
    environment_variable {
      name  = "TF_VAR_acme_email"
      value = var.acme_email
    }
    environment_variable {
      name  = "TF_VAR_acme_use_staging"
      value = tostring(var.acme_use_staging)
    }
  }

  vpc_config {
    vpc_id             = var.vpc_id
    subnets            = [var.vpc_subnet_id]
    security_group_ids = [aws_security_group.codebuild.id]
  }

  logs_config {
    cloudwatch_logs {
      group_name = "/aws/codebuild/eksmanager-lets-encrypt"
    }
  }
}

# ── EventBridge ──────────────────────────────────────────────────────────────

resource "aws_iam_role" "eventbridge_codebuild" {
  provider = aws.shared
  name     = "EKSManagerLetsEncryptEventBridgeRole"

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
  name     = "EKSManagerLetsEncryptEventBridgeStartBuild"
  role     = aws_iam_role.eventbridge_codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "codebuild:StartBuild"
      Resource = aws_codebuild_project.lets_encrypt.arn
    }]
  })
}

# Trigger 1 -- the artifact changed. Code or zone list edits apply immediately.
resource "aws_cloudwatch_event_rule" "artifact_uploaded" {
  provider    = aws.shared
  name        = "eksmanager-lets-encrypt-artifact-uploaded"
  description = "Runs the Let's Encrypt pipeline when lets-encrypt.zip is uploaded"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [local.lets_encrypt_bucket] }
      object = { key = [local.artifact_key] }
    }
  })
}

resource "aws_cloudwatch_event_target" "start_on_upload" {
  provider = aws.shared
  rule     = aws_cloudwatch_event_rule.artifact_uploaded.name
  arn      = aws_codebuild_project.lets_encrypt.arn
  role_arn = aws_iam_role.eventbridge_codebuild.arn

  input_transformer {
    input_template = jsonencode({
      sourceLocationOverride = "${local.lets_encrypt_bucket}/${local.artifact_key}"
    })
  }
}

# Trigger 2 -- renewal. Runs the same apply against whatever artifact is
# currently in the bucket; the provider reissues only what is inside
# min_days_remaining, so most of these runs change nothing.
resource "aws_cloudwatch_event_rule" "weekly_renewal" {
  provider            = aws.shared
  name                = "eksmanager-lets-encrypt-weekly-renewal"
  description         = "Weekly Let's Encrypt renewal check"
  schedule_expression = var.renewal_schedule_expression
}

resource "aws_cloudwatch_event_target" "start_on_schedule" {
  provider = aws.shared
  rule     = aws_cloudwatch_event_rule.weekly_renewal.name
  arn      = aws_codebuild_project.lets_encrypt.arn
  role_arn = aws_iam_role.eventbridge_codebuild.arn

  input_transformer {
    input_template = jsonencode({
      sourceLocationOverride = "${local.lets_encrypt_bucket}/${local.artifact_key}"
    })
  }
}
