# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# A child module: the provider and the backend are the caller's.
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}
