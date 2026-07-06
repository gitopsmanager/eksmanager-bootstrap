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

resource "aws_instance" "agent" {
  ami                    = coalesce(var.agent_ami, data.aws_ami.ubuntu_jammy.id)
  instance_type          = var.agent_instance_type
  subnet_id              = var.agent_subnet_id
  vpc_security_group_ids = [var.agent_security_group_id]
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

  # Replace the instance if the install URLs change (new agent version).
  # user_data changes alone don't trigger replacement by default in Terraform.
  user_data_replace_on_change = true

  tags = {
    Name = var.agent_name
  }

  lifecycle {
    # Prevent accidental replacement during normal re-plans when URLs
    # haven't changed. Only replace when user_data actually differs.
    create_before_destroy = true
  }
}
