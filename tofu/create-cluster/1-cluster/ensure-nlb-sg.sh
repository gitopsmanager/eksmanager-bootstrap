#!/usr/bin/env bash
# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# Create <cluster>-nlb-sg once, as the agent's create_nlb_security_group did
# (packages/awsapi create_nlb_security_group), and never touch it again.
#
# Not an aws_security_group resource: creating one makes OpenTofu revoke and
# re-add the default egress rule, and later reconcile tags and egress, none of
# which EKSManagerAdminRole is allowed to do (it may tag a security group only
# while creating it, and has no egress permissions). Like the agent:
#   - found by VPC and Name tag, and left alone when it exists;
#   - otherwise created with Name, EKSManager=Managed and the cost tag, all at
#     creation; no ingress rules (add-cluster-network adds them); AWS's default
#     allow-all egress, which NLB health checks need.
#
# Called by terraform_data.nlb_sg with: ROLE_ARN REGION VPC_ID NAME DESCRIPTION
# COST_TAG_NAME COST_TAG_VALUE (cost tag empty for none).
set -euo pipefail

creds=$(aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name eksmanager-create-nlb-sg \
  --query Credentials --output json)
export AWS_ACCESS_KEY_ID=$(printf '%s' "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKeyId"])')
export AWS_SECRET_ACCESS_KEY=$(printf '%s' "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["SecretAccessKey"])')
export AWS_SESSION_TOKEN=$(printf '%s' "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["SessionToken"])')
export AWS_REGION="$REGION"

existing=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=$NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ -n "$existing" ] && [ "$existing" != None ]; then
  echo "Security group $NAME ($existing) already exists in $VPC_ID, skipping."
  exit 0
fi

tags="{Key=Name,Value=$NAME},{Key=EKSManager,Value=Managed}"
[ -n "${COST_TAG_NAME:-}" ] && tags="$tags,{Key=$COST_TAG_NAME,Value=${COST_TAG_VALUE:-}}"
id=$(aws ec2 create-security-group --group-name "$NAME" --description "$DESCRIPTION" --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[$tags]" --query GroupId --output text)
echo "Created security group $NAME ($id) in $VPC_ID."
