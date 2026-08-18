# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform-aws-eksmanager — providers.tf
# -----------------------------------------------------------------------------
# Three providers:
#   default              — management account, reached by assuming
#                          EKSManagerBootstrap from CodeBuild's own role
#                          (EKSManagerBootstrapSharedRole, in shared services)
#   aws.shared           — shared services account. No assume_role -- CodeBuild's
#                          own execution role already runs here directly.
#   aws.management_untagged — same identity as default, no default_tags. Used
#                          only by module.scp. See the note on that provider.
#
# Child accounts are never targeted directly — the StackSet handles deployment
# into spoke accounts on behalf of the module.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.11.0" # use_lockfile (S3 native locking) is GA from 1.11; experimental-only in 1.10

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0.0"
    }
  }

  # State lives in the same S3 bucket already used to store the
  # eksmanager-bootstrap.zip source (versioned, see
  # iam/codebuild-pipeline-tf/main.tf's aws_s3_bucket.bootstrap) under a
  # separate state/ prefix -- one less bucket to create and manage.
  # bucket/region can't be set here: backend blocks are evaluated before
  # any variable is available, so both are supplied via -backend-config at
  # `terraform init` time (buildspec.yml), computed from the same
  # shared_services_account_id/region already in pinned.auto.tfvars.json.
  # use_lockfile replaces the traditional DynamoDB lock table entirely --
  # no separate table to create or grant permissions on.
  backend "s3" {
    key          = "state/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

locals {
  # The customer's cost-allocation tag, merged into every provider's
  # default_tags. Omitted entirely when no key is configured -- an empty tag key
  # is rejected by the AWS API rather than ignored.
  extra_tags = var.resource_tag_name == "" ? {} : {
    (var.resource_tag_name) = var.resource_tag_value
  }

  # Keys are spaced because that is the form the customer's AWS reseller asked
  # for. Unusual, and awkward in IAM conditions -- "aws:RequestTag/Managed By"
  # -- but no condition anywhere keys off these, so the cost is only cosmetic.
  # The access boundary uses the separate EKSManager tag, which is untouched.
  #
  # "Managed By" names what CREATED the resource, not what asked for it. Every
  # resource in this module is Terraform's, so it is Terraform here. Resources
  # the agent creates directly through boto3 -- the EKS cluster, its node
  # groups -- carry EKSManagerAgent instead, and are tagged by the agent rather
  # than from here. The distinction matters for the prefix list rules: the
  # server dispatches that build, but Terraform is what creates them, so they
  # are Terraform too.
  #
  # "Environment" is production for everything in this module. These resources
  # -- the buckets, the pipelines, the shared roles -- serve every cluster the
  # installation manages, whatever environment each of those is. This IS the
  # production installation for the client. Per-cluster resources carry the DNS
  # zone prefix instead, set where they are created.
  #
  # ManagedBy (unspaced) stays alongside "Managed By". They look alike and are
  # not: ManagedBy=EKSManager says which system OWNS the resource, "Managed
  # By"=Terraform says which mechanism CREATED it. Both are true and neither
  # implies the other.
  #
  # It was briefly dropped as a near-duplicate. Adding tags needs only Tag*,
  # which the CodeBuild role has; REMOVING one needs Untag*, which it does not
  # -- so the apply failed on iam:UntagInstanceProfile and
  # cloudformation:UntagResource with nothing pointing at a tag change. The
  # stackset template writes ManagedBy onto EKSManagerAdminRole in every spoke
  # account too, so dropping it here would also have split that convention in
  # half.
  #
  # Worth knowing before changing this map again: any future REMOVAL hits the
  # same wall, and the missing permissions are iam:UntagInstanceProfile and
  # cloudformation:UntagResource.
  common_tags = merge({
    "ManagedBy"   = "EKSManager"
    "Deployed By" = "GitOpsManager"
    "Managed By"  = "Terraform"
    "Environment" = "production"
    "Module"      = "terraform-aws-eksmanager"
  }, local.extra_tags)
}

# Management account — runner must authenticate here
provider "aws" {
  region = var.management_account_region

  assume_role {
    role_arn     = "arn:aws:iam::${var.management_account_id}:role/EKSManagerBootstrap"
    session_name = "EKSManagerBootstrap"
  }

  default_tags {
    tags = local.common_tags
  }
}

# Management account, deliberately WITHOUT default_tags. Used only by
# module.scp.
#
# aws_organizations_policy is the first taggable resource this module creates in
# the management account -- aws_organizations_aws_service_access and
# aws_organizations_delegated_administrator, the only others, do not take tags.
# So default_tags had never produced a tagging call there until the SCPs were
# added, and the first apply failed with a bare AccessDeniedException from
# CreatePolicy: Organizations authorises tag-on-create against
# organizations:TagResource, which EKSManagerBootstrap was not granted.
#
# The fix could have been to grant it. This is the cheaper answer: nothing reads
# an SCP's tags, the policy names identify themselves, and the SCP's own KMS
# statement keys off the KMS key's tag rather than its own. Untagged, the role
# needs only organizations:ListTagsForResource -- read-only, and scoped to
# policy ARNs -- instead of TagResource plus UntagResource. UntagResource in
# particular is worth not holding: on "*" it would let this role strip tags from
# accounts and OUs, which customers use for their own controls.
#
# ListTagsForResource is still required even with no tags, because the provider
# reads tags back on every refresh of a taggable resource.
#
# If a reviewer later wants SCPs tagged, switch module.scp back to the default
# provider and restore TagResource/UntagResource on arn:aws:organizations::*:policy/*
# -- both parts have to move together.
provider "aws" {
  alias  = "management_untagged"
  region = var.management_account_region

  assume_role {
    role_arn     = "arn:aws:iam::${var.management_account_id}:role/EKSManagerBootstrap"
    session_name = "EKSManagerBootstrapSCP"
  }
}

# Shared services account — CodeBuild's own execution role
# (EKSManagerBootstrapSharedRole) already runs here directly, so no
# assume_role hop is needed or used. Kept as a distinct provider alias
# (rather than just reusing the default provider) so callers stay explicit
# about which account a resource belongs to.
provider "aws" {
  alias  = "shared"
  region = var.shared_services_region

  default_tags {
    tags = local.common_tags
  }
}
