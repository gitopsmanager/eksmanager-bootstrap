#!/usr/bin/env bash
# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# Apply core-stack argo-cd's "infra" AppProject, once Argo CD (and so its
# CRDs) is installed. It cannot be part of helm_release.argo_cd: Helm maps
# every object before installing any, and the AppProject kind does not exist
# until that same release has installed Argo CD's CRDs.
#
# Rendered from the same chart and values, so when Argo CD later syncs its own
# Application (argo-cd.yml) the project is already exactly what it renders:
# its server-side apply finds no field with a different value, so no conflict.
#
# Called by terraform_data.infra_project with: ROLE_ARN REGION CLUSTER CHART
# and SET_ARGS (the helm --set arguments, space separated, no spaces inside).
set -euo pipefail

creds=$(aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name eksmanager-create-infra-project \
  --query Credentials --output json)
export AWS_ACCESS_KEY_ID=$(printf '%s' "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKeyId"])')
export AWS_SECRET_ACCESS_KEY=$(printf '%s' "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["SecretAccessKey"])')
export AWS_SESSION_TOKEN=$(printf '%s' "$creds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["SessionToken"])')
export AWS_REGION="$REGION"

export KUBECONFIG
KUBECONFIG=$(mktemp)
trap 'rm -f "$KUBECONFIG"' EXIT
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --kubeconfig "$KUBECONFIG" >/dev/null

set_flags=()
for s in $SET_ARGS; do set_flags+=(--set "$s"); done

# The chart's dependency was fetched by helm_release.argo_cd (dependency_update).
helm template argo-cd "$CHART" -n argocd --show-only templates/appproject.yaml "${set_flags[@]}" \
  | kubectl apply --server-side --field-manager=core-stack -f -
