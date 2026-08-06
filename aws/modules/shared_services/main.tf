# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# modules/shared_services — Step 5 + 6 (partial)
# Resources in the shared services account:
#   - ECR repository
#   - Secrets Manager secret
#   - S3 config bucket (versioned, public access blocked)
#   - EKSManagerAgentRole (agent-role-trust.json + agent-role-policy.json)
#   - EC2 instance profile for agent VM
#
# -----------------------------------------------------------------------------

data "aws_caller_identity" "shared" {}

# --- ECR ---------------------------------------------------------------------

resource "aws_ecr_repository" "app" {
  name                 = "eksmanager"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# --- Cross-account ECR push role ---------------------------------------------
#
# The registry lives here, in shared services, but the build runners that push
# to it live in the workload accounts. A repository policy cannot cover them:
# builds create a repository per app on the fly, and ecr:CreateRepository has
# no repository to carry a policy. So the runners chain into this role instead,
# via the targetRoleArn on their EKS Pod Identity association, and run as a
# principal in the account that owns the registry.
#
# Workload accounts come from allowed_regions.json, which the agent already
# uses to decide which accounts it may act on -- so this trust stays in step
# with that list rather than being a second one to maintain.
locals {
  push_ecr_accounts = try(keys(jsondecode(var.allowed_regions_json)["accounts"]), [])
}

resource "aws_iam_role" "ecr_push" {
  # Skipped when no workload accounts are configured yet: a trust policy with
  # an empty principal list is rejected outright.
  count = length(local.push_ecr_accounts) > 0 ? 1 : 0

  name        = "EKSManager-push-ecr"
  description = "Assumed by workload-account build runners to create and push ECR repositories"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = [for acct in local.push_ecr_accounts : "arn:aws:iam::${acct}:root"]
      }
      # TagSession as well as AssumeRole -- Pod Identity carries session tags
      # through the chain and the hop fails without it.
      Action = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        # Naming the accounts alone would let any role in them assume this.
        # This narrows it to the per-cluster roles the agent creates, whose
        # names it controls: EKSManager-<cluster>-push-ecr.
        #
        # Built from the same list as Principal above rather than wildcarding
        # the account, so the two cannot drift apart. ArnLike matches if any
        # entry matches.
        #
        # Note what this does *not* do: anyone who can create a role in a
        # trusted account can create one matching this name. Only a condition
        # on the Pod Identity session tags (kubernetes-namespace and
        # kubernetes-service-account, which a hand-made role cannot set) would
        # close that -- tighten here once CloudTrail confirms which tags
        # actually survive the second hop.
        ArnLike = {
          "aws:PrincipalArn" = [
            for acct in local.push_ecr_accounts : "arn:aws:iam::${acct}:role/EKSManager-*-push-ecr"
          ]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "ecr_push" {
  count = length(local.push_ecr_accounts) > 0 ? 1 : 0

  name = "EKSManagerEcrPushPolicy"
  role = aws_iam_role.ecr_push[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Not resource-scoped by ECR -- it issues a token for the whole
        # registry, so it can only be granted on "*".
        Sid      = "AuthToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        # Create and push only. DeleteRepository and BatchDeleteImage are
        # deliberately absent: a build that can delete other apps' images is a
        # much larger blast radius than one that can add its own.
        Sid    = "CreateAndPush"
        Effect = "Allow"
        Action = [
          "ecr:CreateRepository",
          "ecr:DescribeRepositories",
          "ecr:DescribeImages",
          "ecr:ListImages",
          "ecr:TagResource",
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = "arn:aws:ecr:${var.shared_services_region}:${var.shared_services_account_id}:repository/*"
      },
    ]
  })
}

# --- S3 state bucket ---------------------------------------------------------

resource "aws_s3_bucket" "config" {
  bucket = var.config_bucket_name
}

resource "aws_s3_bucket_versioning" "config" {
  bucket = aws_s3_bucket.config.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "allowed_regions" {
  bucket       = aws_s3_bucket.config.id
  key          = "allowed_regions.json"
  content      = var.allowed_regions_json
  content_type = "application/json"
  # etag forces an update whenever the content actually changes (topology.json
  # edits), rather than only on the object's first creation.
  etag = md5(var.allowed_regions_json)
}

# --- S3 log bucket -----------------------------------------------------------
# Destination for agent_log_shipper. The name is not configured anywhere: the
# shipper derives it from the account id it reads out of instance metadata, so
# it must stay "eksmanager-logs-<account-id>". If that name were ever taken
# globally this resource fails to create, which is the loud early failure we
# want rather than the agent discovering it later as an access denied.

resource "aws_s3_bucket" "logs" {
  bucket = "eksmanager-logs-${data.aws_caller_identity.shared.account_id}"
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 30 days in Standard, no tiering. The objects are 5-minute batches of a few KB
# each, and every archival class bills a 128 KB minimum per object -- moving
# them to Glacier would bill roughly 11 GB for the ~1 GB actually stored, plus
# transition requests. At this size Standard is the cheap option: 30 days costs
# well under a cent a month, and the request charges dominate regardless.
resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-after-30-days"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }

    # Uploads that never completed are billed until aborted.
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# --- EKSManagerAgentRole -----------------------------------------------------
# Trust:  agent-role-trust.json  (ec2.amazonaws.com)
# Policy: agent-role-policy.json with substitutions:
#   MGMT_ACCOUNT_ID            → management account ID
#   SHARED_SERVICES_ACCOUNT_ID → shared services account ID

resource "aws_iam_role" "agent" {
  name        = "EKSManagerAgentRole"
  description = "Runtime identity of EKS Manager agent VM"

  assume_role_policy = file("${path.module}/agent-role-trust.json")
}

resource "aws_iam_role_policy" "agent" {
  name = "EKSManagerAgentPolicy"
  role = aws_iam_role.agent.id

  policy = templatefile("${path.module}/agent-role-policy.json", {
    SHARED_SERVICES_ACCOUNT_ID = data.aws_caller_identity.shared.account_id
    IDENTITY_CENTER_ROLE_ARN   = var.eks_manager_identity_center_role_arn
  })
}

resource "aws_iam_role_policy_attachment" "agent_ssm_core" {
  role       = aws_iam_role.agent.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "agent" {
  name = "EKSManagerAgentRole"
  role = aws_iam_role.agent.name
}
