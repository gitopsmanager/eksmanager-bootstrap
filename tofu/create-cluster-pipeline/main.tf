# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# The create runner: a CodeBuild project registered as a GitHub Actions
# runner for the client's private bootstrap repo, its state bucket and its
# role. Nothing runs between jobs: GitHub queues a job labelled
# codebuild-<project>-..., the webhook starts one build for it, and the
# build is the runner for that one job. Logs stay in GitHub.
#
# TEMPORARY -- MUST CHANGE: while run_as_agent_role is true (the default for
# the agent migration), the container runs AS EKSManagerAgentRole. That role
# already reaches every workload account (EKSManagerAdminRole trusts it) and
# is already exempt from the secrets SCP, so the first runs need no other
# trust or SCP change. The runner's own role, EKSManager-runner-create, is
# created here regardless, with the same runtime permissions, for when the
# runner moves to it: then EKSManagerAdminRole's trust and the secrets SCP
# name it (core-stack docs/aws-roles-and-scp.md), run_as_agent_role goes to
# false, and aws/'s agent_role_trust_codebuild goes back to false.
# -----------------------------------------------------------------------------

locals {
  bucket         = "eksmanager-clusters-${var.shared_services_account_id}"
  role_name      = "EKSManager-runner-create"
  log_group      = "/aws/codebuild/${var.project_name}"
  connection_arn = !var.codebuild_runner ? "" : (var.codeconnections_arn != "" ? var.codeconnections_arn : aws_codeconnections_connection.github[0].arn)

  agent_role_name = "EKSManagerAgentRole"
  agent_role_arn  = "arn:aws:iam::${var.shared_services_account_id}:role/${local.agent_role_name}"
  service_role    = var.run_as_agent_role ? local.agent_role_arn : aws_iam_role.runner.arn

  # From ECR, CodeBuild pulls with the service role; from any other registry
  # (ghcr.io, public) with its own credentials.
  image_from_ecr = can(regex("\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/", var.runner_image))

  # What the create needs, whichever runner and role it runs as: the state
  # bucket, the runner image, and the EKSManager config in SSM; on the
  # CodeBuild runner (codebuild_runner) also its logs, the GitHub connection
  # and its network interface in the agent subnet.
  runtime_statements = [
    for s in local.all_runtime_statements : s
    if var.codebuild_runner || !contains(["Logs", "GitHubConnection", "AttachToTheAgentSubnet"], s.Sid)
  ]
  all_runtime_statements = [
    {
      Sid      = "StateBucket"
      Effect   = "Allow"
      Action   = ["s3:ListBucket"]
      Resource = aws_s3_bucket.state.arn
    },
    {
      Sid      = "StateObjects"
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      Resource = "${aws_s3_bucket.state.arn}/accounts/*"
    },
    {
      Sid      = "Logs"
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.runner.arn}:*"
    },
    {
      Sid    = "PullTheRunnerImage"
      Effect = "Allow"
      Action = [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchImportUpstreamImage",
      ]
      Resource = "*"
    },
    {
      Sid      = "GitHubConnection"
      Effect   = "Allow"
      Action   = ["codeconnections:UseConnection", "codeconnections:GetConnectionToken", "codestar-connections:UseConnection", "codestar-connections:GetConnectionToken"]
      Resource = local.connection_arn
    },
    {
      Sid    = "RunInTheVpc"
      Effect = "Allow"
      Action = [
        "ec2:CreateNetworkInterface",
        "ec2:DescribeDhcpOptions",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DeleteNetworkInterface",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeVpcs",
      ]
      Resource = "*"
    },
    {
      Sid      = "AttachToTheAgentSubnet"
      Effect   = "Allow"
      Action   = "ec2:CreateNetworkInterfacePermission"
      Resource = "arn:aws:ec2:${var.region}:${var.shared_services_account_id}:network-interface/*"
      Condition = {
        StringEquals = {
          "ec2:Subnet"            = [data.aws_subnet.agent.arn]
          "ec2:AuthorizedService" = "codebuild.amazonaws.com"
        }
      }
    },
    {
      Sid      = "ReadEKSManagerConfig"
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters"]
      Resource = "arn:aws:ssm:${var.region}:${var.shared_services_account_id}:parameter/EKSManager/config/*"
    },
  ]
}

# Created PENDING. Approving it is the one manual step: in the console, open
# Developer Tools -> Settings -> Connections, choose eksmanager-github,
# "Update pending connection", and install or pick the GitHub App for the
# org. Then re-run setup, which adds the webhook.
resource "aws_codeconnections_connection" "github" {
  count         = var.codebuild_runner && var.codeconnections_arn == "" ? 1 : 0
  name          = "eksmanager-github"
  provider_type = "GitHub"
}

data "aws_subnet" "agent" {
  id = var.agent_subnet_id
}

# ------------------------------------------------------------ state bucket
# One state per cluster per stage:
#   accounts/<account>/clusters/<cluster>/<stage>.tfstate
# Its own bucket, as every bootstrap pipeline has: OpenTofu's states never
# share a bucket with Terraform's.

resource "aws_s3_bucket" "state" {
  bucket = local.bucket
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Old state versions kept a year: enough to restore from, without growing
# forever (each apply writes a new version).
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# ------------------------------------------------------------- runner role
# The runner's own identity, for when it stops running as the agent role.
# Until then it exists but no project uses it.

resource "aws_iam_role" "runner" {
  name = local.role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = var.shared_services_account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "runner" {
  name = "EKSManagerRunnerCreate"
  role = aws_iam_role.runner.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid      = "AssumeIntoTheWorkloadAccounts"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole", "sts:TagSession"]
        Resource = var.assumable_role_arns
      }],
      local.runtime_statements,
    )
  })
}

# TEMPORARY -- MUST CHANGE: the same runtime permissions on the agent role,
# because the container runs as it. A separate inline policy, so the agent's
# own (EKSManagerAgentPolicy, owned by aws/) is untouched. Goes away with
# run_as_agent_role.
resource "aws_iam_role_policy" "agent_runtime" {
  count = var.run_as_agent_role ? 1 : 0
  name  = "EKSManagerCreateClusterRunner"
  role  = local.agent_role_name
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.runtime_statements
  })
}

# ------------------------------------------------------------------ network

resource "aws_security_group" "runner" {
  name        = "${var.project_name}-runner"
  description = "CodeBuild create runner: outbound only"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_cloudwatch_log_group" "runner" {
  name              = local.log_group
  retention_in_days = var.log_retention_days
}

# ----------------------------------------------------------- the project
# Created only once its service role trusts CodeBuild: CreateProject refuses
# a role CodeBuild cannot assume. Running as the agent role, that trust comes
# from the bootstrap build (aws/'s agent_role_trust_codebuild), so on a
# first install the project appears on the next setup run -- the same re-run
# the connection approval needs. setup-pipeline.sh sets service_role_ready.

resource "aws_codebuild_source_credential" "github" {
  count       = var.codebuild_runner && var.manage_source_credential && var.connection_ready ? 1 : 0
  auth_type   = "CODECONNECTIONS"
  server_type = "GITHUB"
  token       = local.connection_arn
}

resource "aws_codebuild_project" "runner" {
  count         = var.codebuild_runner && var.service_role_ready ? 1 : 0
  name          = var.project_name
  description   = "GitHub Actions runner for bootstrap-create-cluster.yml (OpenTofu)"
  service_role  = local.service_role
  build_timeout = var.build_timeout_minutes

  source {
    type            = "GITHUB"
    location        = "${var.github_repo_url}.git"
    git_clone_depth = 1
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type                        = "LINUX_CONTAINER"
    compute_type                = var.compute_type
    image                       = var.runner_image
    image_pull_credentials_type = local.image_from_ecr ? "SERVICE_ROLE" : "CODEBUILD"
    privileged_mode             = false
  }

  vpc_config {
    vpc_id             = var.vpc_id
    subnets            = [var.agent_subnet_id]
    security_group_ids = [aws_security_group.runner.id]
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.runner.name
    }
  }

  depends_on = [
    aws_codebuild_source_credential.github,
    aws_iam_role_policy.agent_runtime,
    aws_iam_role_policy.runner,
  ]
}

# One build per queued workflow job that asks for this project. Only once the
# project exists and the connection is approved.
resource "aws_codebuild_webhook" "runner" {
  count        = var.codebuild_runner && var.service_role_ready && var.connection_ready ? 1 : 0
  project_name = aws_codebuild_project.runner[0].name
  build_type   = "BUILD"

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "WORKFLOW_JOB_QUEUED"
    }
  }
}
