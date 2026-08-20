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
    key          = "setup/lets-encrypt-pipeline/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
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
      "ManagedBy"   = "EKSManager"
      "Deployed By" = "GitOpsManager"
      "Managed By"  = "Terraform"
      "Environment" = "production"
      "Module"      = "eksmanager-lets-encrypt-pipeline"
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

  # GitHub's immutable subject-claim format (auto-enforced for repos created
  # after July 15, 2026): repo:OWNER@OWNER-ID/REPO@REPO-ID -- falls back to
  # the legacy repo:OWNER/REPO format when either ID is unset, for repos
  # that predate the change and haven't opted in.
  #
  # The IDs belong in the sub, not in conditions of their own. There is no
  # owner_id claim in a GitHub OIDC token -- the claim is repository_owner_id
  # -- and StringEquals on a claim the token does not carry evaluates false,
  # so a condition naming it denies every assume with no indication why.
  # Identical to the local of the same name in codebuild-pipeline-tf and
  # prefix-lists-pipeline-tf, which is what those two get right.
  github_sub_repo = (var.github_owner_id != "" && var.github_repo_id != "") ? (
    "${split("/", var.github_repo)[0]}@${var.github_owner_id}/${split("/", var.github_repo)[1]}@${var.github_repo_id}"
  ) : var.github_repo
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
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # Pinned to refs/heads/main, matching the other two pipelines.
          #
          # It was a wildcard so either workflow could run from any branch. But
          # the sub claim is the only thing between "can push a branch" and
          # "holds this role", and repo write is held more widely than it looks
          # -- contractors, CI tooling, a leaked PAT. These two workflows reach
          # identities that rewrite IAM in this account and run Terraform as
          # EKSManagerLetsEncryptRole, so they are the two that least deserve a
          # wildcard.
          #
          # Consequence: dispatching from a feature branch no longer works. Merge
          # first, then dispatch from main.
          "token.actions.githubusercontent.com:sub" = "repo:${local.github_sub_repo}:ref:refs/heads/main"
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

  # Kept as a file rather than inline so it can be linked to and reviewed
  # directly -- this ARN goes into customer trust policies, so the reviewer is
  # often someone outside this repo. Same pattern as
  # ../codebuild-pipeline-tf/policies/.
  assume_role_policy = file("${path.module}/policies/EKSManagerLetsEncryptRole-trust.json")
}

resource "aws_iam_role_policy" "codebuild" {
  provider = aws.shared
  name     = "EKSManagerLetsEncryptRolePolicy"
  role     = aws_iam_role.codebuild.id

  # The cross-account sts:AssumeRole grant is NOT in this file. It lives in a
  # second inline policy, EKSManagerLetsEncryptAssumeRoles, written by
  # .github/workflows/sync-hosted-zones.yml from hosted-zones.json --
  # see policies/EKSManagerLetsEncryptAssumeRoles-example.json.
  #
  # Separate because put-role-policy replaces an inline policy wholesale: if
  # the workflow wrote this one it would erase everything in it, and if
  # Terraform wrote that one they would overwrite each other on every run.
  policy = templatefile("${path.module}/policies/EKSManagerLetsEncryptRole-policy.json", {
    SHARED_SERVICES_REGION     = var.shared_services_region
    SHARED_SERVICES_ACCOUNT_ID = var.shared_services_account_id
    BUCKET_ARN                 = aws_s3_bucket.lets_encrypt.arn
    STATE_KEY                  = local.state_key
  })
}

# See the note in iam/codebuild-pipeline-tf/main.tf: CodeBuild creates this
# implicitly, leaving it unmanaged and untagged. Imported by setup-pipeline.sh
# where it already exists.
resource "aws_cloudwatch_log_group" "lets_encrypt" {
  provider = aws.shared
  name     = "/aws/codebuild/eksmanager-lets-encrypt"
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
    # TF_VAR_acme_email and TF_VAR_acme_use_staging are deliberately absent.
    # The buildspec reads acme-email and acme-staging from the top of
    # hosted-zones.json and exports them, so changing the contact or
    # switching to staging is a file edit plus a workflow run -- no Terraform
    # apply against this module, and nothing to supply at setup time.
  }

  # Deliberately NOT VPC-attached, unlike the bootstrap and prefix-lists
  # projects. Those must egress through a known NAT address because the EKS
  # Manager API is IP-allowlisted. This one talks only to Let's Encrypt, STS,
  # Route53 and Secrets Manager -- none allowlisted, all reachable from
  # AWS-managed networking. Attaching it anyway would require the four ENI
  # permissions CodeBuild needs to place an interface in the subnet, widening
  # the role for no benefit.

  logs_config {
    cloudwatch_logs {
      group_name = "/aws/codebuild/eksmanager-lets-encrypt"
    }
  }
}

# ── Policy-sync role ────────────────────────────────────────────────────────
# Assumed by .github/workflows/sync-hosted-zones.yml, which writes the
# EKSManagerLetsEncryptAssumeRoles inline policy from the cert_manager ARNs in
# hosted-zones.json. That is its only job.
#
# Separate from the upload role above because they do genuinely different
# things: one puts an object in a bucket, this one writes an IAM policy. Sharing
# an identity would mean the artifact upload also carried IAM write.

resource "aws_iam_role" "policy_sync" {
  provider = aws.shared
  name     = "EKSManagerLetsEncryptPolicySyncRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.github_oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # Pinned to refs/heads/main -- see the upload role above.
          # sync-hosted-zones.yml carries a matching branches: [main] filter, so
          # a push to any other branch neither triggers the workflow nor
          # satisfies this claim.
          "token.actions.githubusercontent.com:sub" = "repo:${local.github_sub_repo}:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "policy_sync" {
  provider = aws.shared
  name     = "EKSManagerLetsEncryptPolicySyncPolicy"
  role     = aws_iam_role.policy_sync.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # One role, and no further. This identity cannot reach any other role
        # in the account.
        #
        # It CAN write any inline policy on that one role, including
        # EKSManagerLetsEncryptRolePolicy, which Terraform owns. That is not
        # the intent -- sync-hosted-zones only ever writes
        # EKSManagerLetsEncryptAssumeRoles -- but it is the tightest bound IAM
        # can actually express. An inline policy has no ARN, so PutRolePolicy
        # takes the ROLE as its resource, and there is no condition key for the
        # policy name. A StringEquals on iam:PolicyName looks like it works and
        # does the opposite: the key is absent from the request context, the
        # condition evaluates false, and every call is denied with "no
        # identity-based policy allows the iam:PutRolePolicy action".
        #
        # What limits the damage is the threat model rather than this grant.
        # Reaching this identity means write access to the client repo, and
        # that already allows editing terraform/lets-encrypt, which CodeBuild
        # then runs AS the role in question. Anyone able to abuse this can
        # already run arbitrary Terraform with the same credentials, so scoping
        # the policy name would buy nothing even if AWS allowed it.
        #
        # To make it a real boundary, the grant has to move to a
        # customer-managed policy -- those do have ARNs, so CreatePolicyVersion
        # scopes to exactly one document. See the note in sync-hosted-zones.yml.
        Sid    = "MaintainAssumeRolesPolicy"
        Effect = "Allow"
        Action = [
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:DeleteRolePolicy",
        ]
        Resource = aws_iam_role.codebuild.arn
      },
    ]
  })
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
