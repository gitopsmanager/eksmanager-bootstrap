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

  # Encrypted with the account's default EBS key rather than EKSManagerCMK.
  # The CMK lives in this same account and would work, but the volume is
  # attached at launch by EC2 itself -- a key policy mistake there is not a
  # failed read, it is an instance that never boots and an agent that never
  # comes back. The data on it is a checkout and a log tail, not secrets;
  # everything that matters is in Secrets Manager or S3, which do use the CMK.
  #
  # Changing this on an existing instance REPLACES it. The agent's local state
  # under /home/ubuntu/.af7 (.subdomain.txt, .vmName.txt) is rebuilt by
  # user_data, so that is a rebuild rather than a data loss -- but it is an
  # outage for that agent, not an in-place update.
  root_block_device {
    volume_size           = 75
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  # IMDSv2 only. Every metadata caller in the agent already does the two-step
  # token exchange -- af7signalr.py and awsapi.py both PUT /latest/api/token
  # before reading anything -- so requiring it breaks nothing.
  #
  # Unlike the volume above, this updates IN PLACE via
  # ModifyInstanceMetadataOptions. No replacement.
  #
  # hop_limit stays at 1: the agent reads its own metadata directly, and a
  # higher limit is what lets a container on the host reach the instance role.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  user_data = templatefile("${path.module}/agent-install.sh.tpl", {
    af7_bundle_download_url    = var.af7_bundle_download_url
    agent_upgrade_download_url = var.agent_upgrade_download_url
    agent_download_url         = var.agent_download_url
    agent_upload_url           = var.agent_upload_url
  })

  tags = {
    Name = var.agent_name
  }

  lifecycle {
    create_before_destroy = true

    # Presigned S3 URLs (af7_bundle_download_url etc.) embed a fresh
    # timestamp + signature on every single API call, regardless of
    # whether the underlying S3 object actually changed -- so user_data
    # differs on every apply even when nothing about the agent itself is
    # different. This, not user_data_replace_on_change, is what actually
    # stops Terraform from touching a running instance over it.
    # user_data_replace_on_change only controls replace-vs-update; with
    # it merely set to false, Terraform still tried an in-place update,
    # which for user_data requires AWS to stop the instance first --
    # exactly the downtime this was meant to avoid, and it failed
    # outright on a missing ec2:StopInstances grant besides.
    # ignore_changes here means Terraform never treats user_data as
    # drift at all once the instance exists -- no replace, no update, no
    # stop/start. Picking up a genuinely new agent version needs an
    # explicit `terraform apply -replace=...` (or `taint`), not an
    # automatic one -- there's no signal available here (like an S3
    # ETag/version ID, as opposed to the URL text itself) that would let
    # Terraform tell "same content, new signature" apart from "new
    # content" on its own.
    ignore_changes = [user_data]
  }
}
