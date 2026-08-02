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
