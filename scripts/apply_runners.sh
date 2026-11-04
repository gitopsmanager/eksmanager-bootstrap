#!/usr/bin/env bash
# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# GitOps Manager's runners (ECS Fargate: the ad-hoc pool, gom-aws-adhoc, and the
# long-job pool, gom-aws-long), applied by buildspec.yml after aws/. SaaS only:
# the subscription's sync delivers the module as runners/; without it (the
# free bootstrap) this does nothing.
#
#   apply_runners.sh apply     plan and apply runners/
#   apply_runners.sh plan      plan only (PLAN_ONLY), say whether anything would change
#   apply_runners.sh destroy   destroy them (DESTROY_MODE), before aws/ goes
#
# Inputs:
#   aws/pinned.auto.tfvars.json   shared services account and region, vpc_id,
#                                 agent_subnet_id
#   .gom/build.json               {"github_org": ..., "runner_image": ...,
#                                 and optionally hot, max, long_max},
#                                 written by bootstrap.yml from the repository
#                                 (owner, and the RUNNER_IMAGE / RUNNERS_*
#                                 variables)
#   EKSMANAGER_CLIENT_ID          set on the SaaS: the runners get the M2M settings
#
# Skips, with a notice, while something it needs is not there yet: the
# runner image, or the organisation's GitHub App secret the GUI writes when
# the App is installed (/EKSManager/global-arc-global-arc-runner-<org>).
# OpenTofu only.
set -euo pipefail

mode="${1:-apply}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

if [ ! -d runners ]; then
  echo "No runners/ in this copy (the free bootstrap): nothing to do."
  exit 0
fi

pinned=aws/pinned.auto.tfvars.json
get() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], '') or '')" "$1" "$2"; }
account=$(get "$pinned" shared_services_account_id)
region=$(get "$pinned" shared_services_region)
vpc=$(get "$pinned" vpc_id)
subnet=$(get "$pinned" agent_subnet_id)
org=""; image=""
if [ -f .gom/build.json ]; then
  org=$(get .gom/build.json github_org)
  image=$(get .gom/build.json runner_image)
fi

tofu -chdir=runners init -input=false -reconfigure \
  -backend-config="bucket=eksmanager-bootstrap-${account}" \
  -backend-config="region=${region}" \
  -backend-config="key=state/runners.tfstate" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true" >/dev/null

if [ "$mode" = destroy ]; then
  if [ -z "$(tofu -chdir=runners state list 2>/dev/null)" ]; then
    echo "No runners in state: nothing to destroy."
    exit 0
  fi
  tofu -chdir=runners destroy -input=false -auto-approve \
    -var="region=${region}" -var="vpc_id=${vpc}" -var="subnet_ids=[\"${subnet}\"]" \
    -var="github_org=${org:-unset}" -var="runner_image=${image:-unset}"
  echo "OK: runners destroyed"
  exit 0
fi

missing=()
[ -n "$vpc" ] || missing+=("vpc_id in $pinned")
[ -n "$subnet" ] || missing+=("agent_subnet_id in $pinned")
[ -n "$org" ] || missing+=("github_org in .gom/build.json (run bootstrap.yml)")
[ -n "$image" ] || missing+=("runner_image in .gom/build.json (repository variable RUNNER_IMAGE)")
if [ ${#missing[@]} -gt 0 ]; then
  echo "NOTICE: runners not applied, missing: ${missing[*]}"
  exit 0
fi
if [ "$(python3 -c "import json; print(str(json.load(open('$pinned')).get('agent_role_trust_ecs_tasks', True)).lower())")" = false ]; then
  echo "NOTICE: runners not applied: $pinned has agent_role_trust_ecs_tasks false, so their tasks could not run as the agent role. Re-run setup-pipeline.sh."
  exit 0
fi
app_secret="/EKSManager/global-arc-global-arc-runner-$(echo "$org" | tr '[:upper:]' '[:lower:]')"
if ! aws secretsmanager describe-secret --secret-id "$app_secret" --region "$region" >/dev/null 2>&1; then
  echo "NOTICE: runners not applied: no $app_secret yet (the GUI writes it when the GitHub App is installed)."
  exit 0
fi

m2m=false
[ -n "${EKSMANAGER_CLIENT_ID:-}" ] && m2m=true

# The runner counts the repository set (bootstrap.yml); the module's
# defaults otherwise (3 hot up to 10; long jobs from 0 up to 10).
counts=()
for key in hot max long_max; do
  v=$(get .gom/build.json "$key" 2>/dev/null || true)
  [ -n "$v" ] && counts+=(-var="${key}=${v}")
done

rc=0
tofu -chdir=runners plan -input=false -out=tfplan -detailed-exitcode \
  -var="region=${region}" -var="vpc_id=${vpc}" -var="subnet_ids=[\"${subnet}\"]" \
  -var="github_org=${org}" -var="runner_image=${image}" -var="m2m=${m2m}" "${counts[@]}" || rc=$?
case "$rc" in
  0) echo "PLAN (runners/): no changes" ;;
  2) echo "PLAN (runners/): changes, listed above" ;;
  *) exit "$rc" ;;
esac
[ "$mode" = plan ] && exit 0
tofu -chdir=runners apply -input=false tfplan
echo "OK: runners applied"
tofu -chdir=runners output
