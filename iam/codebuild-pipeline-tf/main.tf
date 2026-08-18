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
    key          = "setup/codebuild-pipeline/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

# Management account — ambient credentials, no assume_role. Whoever runs
# terraform apply must already be authenticated here.
provider "aws" {
  region = var.management_account_region

  default_tags {
    tags = {
      "ManagedBy"   = "EKSManager"
      "Deployed By" = "GitOpsManager"
      "Managed By"  = "Terraform"
      "Environment" = "production"
      "Module"      = "eksmanager-codebuild-pipeline"
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
      "ManagedBy"   = "EKSManager"
      "Deployed By" = "GitOpsManager"
      "Managed By"  = "Terraform"
      "Environment" = "production"
      "Module"      = "eksmanager-codebuild-pipeline"
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

# ── IAM Identity Center — permission sets + cross-account trust ─────────────
# Identity Center itself (SAML federation, SCIM group sync) is managed by
# the infra team, not this repo -- this only creates the two permission
# sets EKSManagerAgentRole is allowed to assign groups to, and the role in
# whichever account administers Identity Center that lets it do so.
#
# aws_ssoadmin_instances only returns a result when queried from the exact
# region the instance actually lives in -- silently empty otherwise, not
# an error. Rather than require the operator to find that region manually
# via the AWS CLI first, this searches every AWS region enabled by default
# (not opt-in -- a foundational, always-needed service like Identity
# Center is virtually never placed in an opt-in region, since that would
# require every account needing SSO access to also individually opt into
# it) using for_each directly on the data source -- region is a per-
# resource argument here, not something requiring a separate provider
# block per region. identity_center_region overrides this entirely if
# set, skipping the search (also the only way to reach an opt-in region
# this candidate list doesn't cover).
#
# AWS now supports replicating one Identity Center instance across
# multiple regions (GA Feb 2026) -- administrative actions like creating
# permission sets only work from the PRIMARY region, though, so finding
# the instance in more than one region here is treated as ambiguous
# rather than picked automatically; the precondition below requires
# identity_center_region to be set explicitly in that case.
#
# Assumes Identity Center is administered from the management account
# itself, not a delegated admin account -- if that's wrong, the search
# finds nothing in any region regardless, and this whole block needs its
# own provider pointed at the correct account instead.
#
# Trusts the shared services account root, not EKSManagerAgentRole's
# specific ARN -- that role doesn't exist yet on first setup-pipeline.sh
# run (it's created later, by the aws/ module). Same pattern as
# EKSManagerBootstrap above: the real enforcement boundary is that only
# EKSManagerAgentRole's own policy actually grants it sts:AssumeRole here,
# not the trust statement itself.

locals {
  identity_center_candidate_regions = var.identity_center_region != "" ? toset([var.identity_center_region]) : toset([
    "us-east-1", "us-east-2", "us-west-1", "us-west-2",
    "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1", "eu-north-1",
    "ap-northeast-1", "ap-northeast-2", "ap-southeast-1", "ap-southeast-2", "ap-south-1",
    "ca-central-1", "sa-east-1"
  ])
}

data "aws_ssoadmin_instances" "search" {
  for_each = local.identity_center_candidate_regions
  region   = each.key
}

locals {
  # Only regions that actually returned an instance.
  identity_center_matches = [
    for region, result in data.aws_ssoadmin_instances.search : {
      region            = region
      instance_arn      = tolist(result.arns)[0]
      identity_store_id = tolist(result.identity_store_ids)[0]
    }
    if length(result.arns) > 0
  ]

  identity_center_instance_arn      = length(local.identity_center_matches) > 0 ? local.identity_center_matches[0].instance_arn : null
  identity_center_identity_store_id = length(local.identity_center_matches) > 0 ? local.identity_center_matches[0].identity_store_id : null
}

resource "aws_ssoadmin_permission_set" "eks_user_view" {
  name             = "EKSManagerUserView"
  description      = "Read-only EKS console/API access -- Kubernetes-level access controlled separately via EKS Access Entries, not this permission set."
  instance_arn     = local.identity_center_instance_arn
  session_duration = "PT4H"
  region           = length(local.identity_center_matches) > 0 ? local.identity_center_matches[0].region : null

  lifecycle {
    precondition {
      condition     = length(local.identity_center_matches) > 0
      error_message = "No IAM Identity Center instance found in any of: ${join(", ", local.identity_center_candidate_regions)}. Either it hasn't been enabled yet, it's in a region not in this candidate list (set identity_center_region explicitly), or it's delegated to a different account entirely (check with: aws organizations list-delegated-administrators)."
    }
    precondition {
      condition     = length(local.identity_center_matches) <= 1
      error_message = "IAM Identity Center instance found in multiple regions (${join(", ", [for m in local.identity_center_matches : m.region])}) -- likely multi-region replication is active. Administrative actions like creating permission sets only work from the primary region; set identity_center_region explicitly to avoid picking the wrong one."
    }
  }
}

resource "aws_ssoadmin_permission_set" "eks_user_admin" {
  name             = "EKSManagerUserAdmin"
  description      = "Admin EKS console/API access -- Kubernetes-level access controlled separately via EKS Access Entries, not this permission set."
  instance_arn     = local.identity_center_instance_arn
  session_duration = "PT4H"
  region           = length(local.identity_center_matches) > 0 ? local.identity_center_matches[0].region : null
}

# Identical on both permission sets -- enough to browse/discover clusters
# and node groups in the console/CLI. The view-vs-admin distinction
# happens entirely at the EKS Access Entry / Access Policy layer later,
# per cluster, not here -- these two permission sets exist mainly so an
# assignment list reads unambiguously (which one someone was granted),
# not because their IAM content differs.
locals {
  eks_connect_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "eks:ListClusters",
        "eks:DescribeCluster",
        "eks:DescribeNodegroup",
        "eks:ListNodegroups"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_ssoadmin_permission_set_inline_policy" "eks_user_view" {
  instance_arn       = local.identity_center_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.eks_user_view.arn
  inline_policy      = local.eks_connect_policy
  region             = length(local.identity_center_matches) > 0 ? local.identity_center_matches[0].region : null
}

resource "aws_ssoadmin_permission_set_inline_policy" "eks_user_admin" {
  instance_arn       = local.identity_center_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.eks_user_admin.arn
  inline_policy      = local.eks_connect_policy
  region             = length(local.identity_center_matches) > 0 ? local.identity_center_matches[0].region : null
}

resource "aws_iam_role" "identity_center" {
  name = "EKSManagerIdentityCenterRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.shared_services_account_id}:root" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "identity_center" {
  name = "EKSManagerIdentityCenterPolicy"
  role = aws_iam_role.identity_center.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Target accounts vary with org_config, which this config has no
        # visibility into -- can't enumerate them here the way the two
        # permission set ARNs are scoped exactly.
        Sid    = "EKSManagerAccountAssignments"
        Effect = "Allow"
        Action = [
          "sso:CreateAccountAssignment",
          "sso:DeleteAccountAssignment",
          "sso:DescribeAccountAssignmentCreationStatus",
          "sso:DescribeAccountAssignmentDeletionStatus"
        ]
        Resource = [
          local.identity_center_instance_arn,
          aws_ssoadmin_permission_set.eks_user_view.arn,
          aws_ssoadmin_permission_set.eks_user_admin.arn,
          "arn:aws:sso:::account/*"
        ]
      },
      {
        # GetGroupId's resource-level scoping isn't well-documented enough
        # to narrow confidently -- Resource "*" here is deliberate, not an
        # oversight, matching the same reasoning already used elsewhere in
        # this file for actions with unclear or unsupported resource-level
        # scoping (e.g. Ec2AgentInstanceLifecycle).
        Sid      = "EKSManagerResolveGroupName"
        Effect   = "Allow"
        Action   = "identitystore:GetGroupId"
        Resource = "*"
      }
    ]
  })
}

# ── EKSManagerCMK ────────────────────────────────────────────────────────────
# One customer-managed key per installation, encrypting everything this system
# stores at rest: the bootstrap artifact bucket and both secrets below, plus the
# config and log buckets created later by aws/modules/shared_services, which
# find it by alias.
#
# Created HERE rather than in aws/ because of ordering. setup-pipeline.sh
# applies this module first, to stand the pipeline up; aws/ is applied later by
# the CodeBuild project this module creates. A key defined there would not exist
# when these buckets and secrets are created.
#
# The policy grants the account root full access and nothing else. That is the
# AWS-recommended shape, not laziness: it delegates authorisation to IAM, so a
# reader is granted by its own role policy rather than by editing this key every
# time a principal is added. Naming principals here as well would mean a key
# policy and an IAM policy that must agree, and the failure when they do not is
# an opaque AccessDenied on a decrypt.
#
# Anything WRITING to an encrypted bucket needs kms:GenerateDataKey* as well as
# kms:Decrypt. Granting Decrypt alone is the usual mistake -- reads work, writes
# fail later, and it reads as a bug somewhere else entirely.
resource "aws_kms_key" "eksmanager" {
  provider = aws.shared

  description = "EKS Manager: encrypts bootstrap artifacts, config, logs and secrets"

  # Rotation is a Well-Architected expectation and costs nothing. Old material
  # is retained, so objects encrypted under a previous year still decrypt.
  enable_key_rotation = true

  # The maximum AWS allows. Deliberately the longest possible: everything this
  # key protects becomes permanently unreadable once deletion completes, and
  # terraform/README documents a `terraform destroy -auto-approve` path. Thirty
  # days is the difference between a recoverable mistake and an unrecoverable
  # one.
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnableIAMPolicies"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.shared_services_account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })

  # The key outlives any single teardown. Destroying it orphans every object in
  # three buckets and both secrets with no way back, so removing it has to be a
  # deliberate act rather than a side effect of destroying this module.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "eksmanager" {
  provider      = aws.shared
  name          = "alias/EKSManagerCMK"
  target_key_id = aws_kms_key.eksmanager.key_id
}

# ── S3 bucket for bootstrap release artifacts ───────────────────────────────
# Terraform-owned — setup-pipeline.sh/.ps1 only sets up infrastructure, it
# doesn't clone, zip, or upload anything, so there's no ordering conflict
# with something else creating this bucket first.

resource "aws_s3_bucket" "bootstrap" {
  provider = aws.shared
  bucket   = local.bootstrap_bucket

  # Holds the bootstrap artifact and, more importantly, is where a destroy would
  # take the only copy of anything not re-uploadable.
  #
  # terraform/README documents a destroy path. This makes removing it a
  # deliberate act -- comment the block out -- rather than a side effect of
  # tearing the module down.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "bootstrap" {
  provider = aws.shared
  bucket   = aws_s3_bucket.bootstrap.id
  versioning_configuration {
    status = "Enabled"
  }
}

# bucket_key_enabled cuts KMS calls by caching a data key per bucket rather than
# per object -- the artifact is uploaded whole on every release, so without it
# each upload is a separate KMS request and a separate charge.
resource "aws_s3_bucket_server_side_encryption_configuration" "bootstrap" {
  provider = aws.shared
  bucket   = aws_s3_bucket.bootstrap.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.eksmanager.arn
    }
    bucket_key_enabled = true
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

  # Without this the secret uses the aws/secretsmanager AWS-managed key, which
  # cannot be audited or restricted per installation.
  kms_key_id = aws_kms_key.eksmanager.arn

  # The M2M credential. Recoverable only by re-running setup with the value to
  # hand, which is not something to discover during a teardown.
  #
  # terraform/README documents a destroy path. This makes removing it a
  # deliberate act -- comment the block out -- rather than a side effect of
  # tearing the module down.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "eksmanager_client_secret" {
  provider      = aws.shared
  secret_id     = aws_secretsmanager_secret.eksmanager_client_secret.id
  secret_string = var.eksmanager_client_secret
}

# ── GitHub App credentials ──────────────────────────────────────────────────
# setup-pipeline.sh/.ps1 doesn't clone anything itself — it just passes
# these straight through to Terraform to persist here, so whatever later
# clones your private copy and uploads eksmanager-bootstrap.zip to S3 has a
# credential to use. Stored as one JSON secret; privateKey is base64,
# matching the GITHUB_APP_PRIVATE_KEY env var format.
# CodeBuild's own role is NOT granted access to this secret — CodeBuild never
# touches GitHub in this design. Any future automation's role would need
# secretsmanager:GetSecretValue on this secret's ARN added explicitly.

resource "aws_secretsmanager_secret" "github_app" {
  provider    = aws.shared
  name        = "/EKSManagerBootstrap/github-app"
  description = "GitHub App credentials (appId, installId, base64 privateKey) used to clone your private copy of eksmanager-bootstrap"

  # Without this the secret uses the aws/secretsmanager AWS-managed key, which
  # cannot be audited or restricted per installation.
  kms_key_id = aws_kms_key.eksmanager.arn

  # The GitHub App private key. If this is the only copy, destroying it means
  # generating a new key pair and re-installing the App.
  #
  # terraform/README documents a destroy path. This makes removing it a
  # deliberate act -- comment the block out -- rather than a side effect of
  # tearing the module down.
  lifecycle {
    prevent_destroy = true
  }
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

# ── GitHub Actions OIDC — .github/workflows/upload-to-s3.yml in your private copy ────
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

  # GitHub's immutable subject-claim format (auto-enforced for repos created
  # after July 15, 2026): repo:OWNER@OWNER-ID/REPO@REPO-ID -- falls back to
  # the legacy repo:OWNER/REPO format when either ID is unset, for repos
  # that predate the change and haven't opted in.
  github_sub_repo = (var.github_owner_id != "" && var.github_repo_id != "") ? (
    "${split("/", var.github_repo)[0]}@${var.github_owner_id}/${split("/", var.github_repo)[1]}@${var.github_repo_id}"
  ) : var.github_repo
}

# ── ECR push trust sync ──────────────────────────────────────────────────────
# EKSManager-push-ecr in shared services is assumed by each cluster's
# EKSManager-<cluster>-push-ecr role, chained into by Pod Identity so ARC
# runners can push images. Its trust used to name the account root with an
# ArnLike wildcard on "EKSManager-*-push-ecr", which meant anyone able to create
# a role matching that name in a trusted account could assume it.
#
# The fix is an exact list of source role ARNs, which has to come from
# clusters.json -- the only place that knows which clusters exist. This role
# lets .github/workflows/sync-ecr-push-trust.yml rebuild that trust whenever the
# file changes.
#
# Same shape and the same reasoning as EKSManagerLetsEncryptPolicySyncRole: a
# list in a JSON file drives one policy on one role, written by one identity, so
# nothing races and a removal is handled by rebuilding the whole document.
#
# Why not do it in terraform/add-cluster, which already runs per cluster: a
# trust policy is a single document and add-cluster keeps per-cluster state, so
# two clusters added at once would each rewrite it from their own state and the
# second would drop the first. It also runs in the workload account with no
# shared services access, so it would need a grant larger than the thing being
# protected.
resource "aws_iam_role" "ecr_push_trust_sync" {
  provider = aws.shared
  name     = "EKSManagerEcrPushTrustSyncRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_provider_final_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # Push-triggered on clusters.json, so the sub carries a ref claim.
        # Same immutable-subject handling as every other OIDC role here.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${local.github_sub_repo}:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "ecr_push_trust_sync" {
  provider = aws.shared
  name     = "EKSManagerEcrPushTrustSyncPolicy"
  role     = aws_iam_role.ecr_push_trust_sync.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      # One role, one action. UpdateAssumeRolePolicy rewrites a trust document
      # wholesale, so this identity can decide who may assume EKSManager-push-ecr
      # -- and nothing else. It cannot touch that role's permissions, which are
      # Terraform's, nor any other role in the account.
      #
      # GetRole so the workflow can show the before and after in its log; a trust
      # policy change that reports nothing is a change nobody can audit.
      Sid    = "MaintainEcrPushTrust"
      Effect = "Allow"
      Action = [
        "iam:UpdateAssumeRolePolicy",
        "iam:GetRole",
      ]
      Resource = "arn:aws:iam::${var.shared_services_account_id}:role/EKSManager-push-ecr"
    }]
  })
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
          # (or repo:<owner>@<owner-id>/<repo>@<repo-id>:ref:... -- see local.github_sub_repo)
          "token.actions.githubusercontent.com:sub" = "repo:${local.github_sub_repo}:ref:refs/heads/main"
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
    Statement = [
      {
        Sid      = "UploadBootstrapZip"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.bootstrap.arn}/eksmanager-bootstrap.zip"
      },
      {
        # The bucket is SSE-KMS now, so a PUT needs the key as well as the
        # bucket. GenerateDataKey, not just Decrypt: S3 asks KMS for a fresh
        # data key on write, and a role holding only Decrypt uploads nothing --
        # it fails as AccessDenied on the PUT, which reads like a bucket policy
        # problem rather than a KMS one.
        Sid    = "EKSManagerCMK"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:DescribeKey",
        ]
        Resource = aws_kms_key.eksmanager.arn
      },
    ]
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

# The StackSetTemplateResourceTypes statement in the policy file below needs an
# entry for every RESOURCE TYPE the StackSet template contains -- CloudFormation
# authorises against those separately from the stackset ARN. Add a resource to
# aws/modules/stackset/eksmanager-enable-account-stackset.yaml and this needs
# updating too, or the bootstrap apply fails with:
#
#   not authorized to perform: cloudformation:UpdateStackSet on resource:
#   arn:aws:cloudformation:<region>::type/resource/AWS-IAM-ManagedPolicy
#
# which names the type rather than the stackset and reads like a stackset
# permission problem. AWS-IAM-ManagedPolicy is EKSManagerRoleBoundary, the
# permissions boundary every EKSManager-* role is created with.
#
# The note lives here because JSON has no comments, and a "_comment" key inside
# a Statement is rejected outright: MalformedPolicyDocument. IAM tolerates it at
# the document top level -- which is why the documentation-only policy files
# under policies/ can carry one -- but not inside a statement.
resource "aws_iam_role_policy" "codebuild" {
  provider = aws.shared
  name     = "EKSManagerBootstrapSharedRolePolicy"
  role     = aws_iam_role.codebuild.id

  policy = templatefile("${path.module}/codebuild-role-policy.json", {
    BOOTSTRAP_BUCKET_ARN          = aws_s3_bucket.bootstrap.arn
    CLIENT_SECRET_ARN             = aws_secretsmanager_secret.eksmanager_client_secret.arn
    MANAGEMENT_BOOTSTRAP_ROLE_ARN = aws_iam_role.management_bootstrap.arn
    SHARED_SERVICES_ACCOUNT_ID    = var.shared_services_account_id
    SHARED_SERVICES_REGION        = var.shared_services_region
    MANAGEMENT_ACCOUNT_ID         = var.management_account_id
  })
}

# ── Network isolation (required) ─────────────────────────────────────────────
# The CodeBuild container runs inside the client's VPC with no inbound access.
# Egress goes via the VPC's NAT Gateway, whose Elastic IP must be the address
# allowlisted on the client's API/GitHub/AWS endpoint firewalls — this is why
# vpc_id and vpc_subnet_id are required, not optional. AWS-managed networking
# would give CodeBuild a different, unpredictable IP on every run.

# The VPC's own CIDR, so DNS egress can be scoped to the Amazon-provided
# resolver (VPC base + 2) rather than to the internet. Without a rule for it
# name resolution fails and every outbound call dies as an unresolvable host,
# which reads like a proxy or firewall problem rather than a missing SG rule.
data "aws_vpc" "bootstrap" {
  provider = aws.shared
  id       = var.vpc_id
}

resource "aws_security_group" "codebuild" {
  provider    = aws.shared
  name        = "eksmanager-bootstrap-codebuild-sg"
  description = "Network perimeter for the EKS Manager bootstrap CodeBuild container - no inbound, egress via VPC routing"
  vpc_id      = var.vpc_id

  # Was every protocol on every port to anywhere. Narrowed to what is actually
  # used: HTTPS out, and DNS to the VPC resolver.
  #
  # 443 stays open to 0.0.0.0/0 rather than to a list of addresses because the
  # destinations are CDN-backed and have no stable ranges to pin --
  # releases.hashicorp.com for the Terraform binary, registry.terraform.io for
  # providers, the ACME API, GitHub, Cognito, and every AWS API endpoint. An
  # allowlist here would be fiction that breaks on the next CDN change.
  #
  # Narrowing this further is a VPC endpoint job, and the VPC belongs to the
  # customer -- see the prerequisites doc. Endpoints for S3, ECR, Secrets
  # Manager and SSM would take that traffic off the internet entirely.
  #
  # No port 80. Nothing here is known to need it; if a package install turns
  # out to, it fails loudly as a connection timeout rather than silently
  # downgrading, which is the right way round.
  egress {
    description = "HTTPS to AWS APIs, the Terraform registry, and other public endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS to the VPC resolver (UDP)"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [data.aws_vpc.bootstrap.cidr_block]
  }

  # TCP as well as UDP: a response over 512 bytes is returned truncated and the
  # resolver retries over TCP. Rare, but it fails as an intermittent DNS error
  # that is very hard to attribute.
  egress {
    description = "DNS to the VPC resolver (TCP, for truncated responses)"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.bootstrap.cidr_block]
  }
}

resource "aws_security_group" "agent" {
  provider    = aws.shared
  name        = "eksmanager-bootstrap-agent-sg"
  description = "EKS Manager agent VM - no inbound, egress only. Agent polls out; nothing connects in."
  vpc_id      = var.vpc_id

  # Was every protocol on every port to anywhere. Narrowed to what is actually
  # used: HTTPS out, and DNS to the VPC resolver.
  #
  # 443 stays open to 0.0.0.0/0 rather than to a list of addresses because the
  # destinations are CDN-backed and have no stable ranges to pin --
  # releases.hashicorp.com for the Terraform binary, registry.terraform.io for
  # providers, the ACME API, GitHub, Cognito, and every AWS API endpoint. An
  # allowlist here would be fiction that breaks on the next CDN change.
  #
  # Narrowing this further is a VPC endpoint job, and the VPC belongs to the
  # customer -- see the prerequisites doc. Endpoints for S3, ECR, Secrets
  # Manager and SSM would take that traffic off the internet entirely.
  #
  # No port 80. Nothing here is known to need it; if a package install turns
  # out to, it fails loudly as a connection timeout rather than silently
  # downgrading, which is the right way round.
  egress {
    description = "HTTPS to AWS APIs, the Terraform registry, and other public endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS to the VPC resolver (UDP)"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [data.aws_vpc.bootstrap.cidr_block]
  }

  # TCP as well as UDP: a response over 512 bytes is returned truncated and the
  # resolver retries over TCP. Rare, but it fails as an intermittent DNS error
  # that is very hard to attribute.
  egress {
    description = "DNS to the VPC resolver (TCP, for truncated responses)"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.bootstrap.cidr_block]
  }

  # Port 80, for the agent VM only. Not an oversight in the narrowing above.
  #
  # agent-install.sh.tpl runs `apt-get install unzip` under `set -euxo
  # pipefail`, and Ubuntu's EC2 mirrors are plain HTTP:
  # eu-west-1.ec2.archive.ubuntu.com:80 and security.ubuntu.com:80. With 443
  # only, apt times out, the script aborts, and the instance comes up with no
  # agent on it -- while `terraform apply` reports success, because it waits
  # for the instance to be RUNNING and never sees cloud-init fail.
  #
  # curl is already in the image; unzip is not, and it is needed to unpack both
  # the af7 bundle and the upgrade bundle. Extracting with python3's zipfile
  # instead would drop the apt dependency, but zipfile does not restore Unix
  # permission bits, so the agent binaries would land non-executable.
  #
  # CodeBuild deliberately does NOT get this: its managed image already carries
  # everything the buildspec uses, and that build passes on 443 alone.
  egress {
    description = "HTTP to Ubuntu package mirrors - apt has no HTTPS source on the stock AMI"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ── CodeBuild project ────────────────────────────────────────────────────────
# Sourced from S3 — never touches GitHub. setup-pipeline.sh/.ps1 only sets
# up this infrastructure; it doesn't clone your private copy or upload anything
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
# that re-clones and re-uploads.

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
