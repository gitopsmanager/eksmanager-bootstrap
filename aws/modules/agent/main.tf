# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# modules/agent — Step 11
# Deploys the EKS Manager agent VM in shared services.
# Install script runs via user_data on first boot — no SSH or SSM commands
# needed from the runner. Downloads are presigned S3 URLs; IAM not required
# for the download step itself.
# -----------------------------------------------------------------------------

# Latest Ubuntu 22.04 (Jammy) build, resolved per-region at apply time --
# always current, no manual AMI-ID maintenance. Pinned to 22.04 specifically
# so a major version bump (e.g. 24.04) only happens when this string is
# deliberately changed, not automatically. owners is Canonical's official
# AWS account -- required, not optional, since anyone can publish an AMI
# with a similar name otherwise.
data "aws_ami" "ubuntu_jammy" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_subnet" "agent" {
  id = var.agent_subnet_id
}

# Created by iam/codebuild-pipeline-tf/main.tf alongside the CodeBuild
# project itself -- fixed name, looked up rather than passed in, since it's
# never known until that Terraform run creates it and there's no reason for
# its ID to travel through topology.json/POST /bootstrap/aws to get here.
data "aws_security_group" "agent" {
  name   = "eksmanager-bootstrap-agent-sg"
  vpc_id = data.aws_subnet.agent.vpc_id
}

resource "aws_instance" "agent" {
  ami                    = coalesce(var.agent_ami, data.aws_ami.ubuntu_jammy.id)
  instance_type          = var.agent_instance_type
  subnet_id              = var.agent_subnet_id
  vpc_security_group_ids = [data.aws_security_group.agent.id]
  iam_instance_profile   = var.agent_role_name

  root_block_device {
    volume_size           = 75
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/agent-install.sh.tpl", {
    af7_bundle_download_url    = var.af7_bundle_download_url
    agent_upgrade_download_url = var.agent_upgrade_download_url
    agent_download_url         = var.agent_download_url
    agent_upload_url           = var.agent_upload_url
  })

  # Presigned S3 URLs (af7_bundle_download_url etc.) embed a fresh
  # timestamp + signature on every single API call, regardless of whether
  # the underlying S3 object actually changed -- so user_data differs on
  # every apply even when nothing about the agent itself is different.
  # Replace-on-change was a false positive every time, tearing down a
  # perfectly running instance on every pipeline run. Disabled: a running
  # instance now stays running. Picking up a genuinely new agent version
  # needs an explicit `terraform apply -replace=...` (or `taint`), not an
  # automatic one -- there's currently no signal available here (like an
  # S3 ETag/version ID, as opposed to the URL text itself) that would let
  # Terraform tell "same content, new signature" apart from "new content"
  # on its own.
  user_data_replace_on_change = false

  tags = {
    Name = var.agent_name
  }

  lifecycle {
    # Prevent accidental replacement during normal re-plans when URLs
    # haven't changed. Only replace when user_data actually differs.
    create_before_destroy = true
  }
}
