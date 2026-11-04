#!/usr/bin/env bash
# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# One stage of tofu/create-cluster: init against the cluster's own state,
# plan, and apply that exact plan (or stop at the plan).
#
#   run_tofu_stage.sh <stage> <account> <cluster> <state-bucket> <state-region> <plan|apply> <tfvars>
#   run_tofu_stage.sh --stop     after a cancel: let OpenTofu stop gracefully
#
# STAGE_DIR, when set, is the module to run instead of tofu/create-cluster/<stage>
# (bootstrap-cluster-identities.yml: tofu/cluster-identities/<identity>). The
# state is accounts/<account>/clusters/<cluster>/<stage>.tfstate either way.
#
# OpenTofu only: this calls `tofu`, never `terraform` (tofu/README.md).
#
# Graceful stop. GitHub kills a cancelled step about 10 seconds after the
# cancel, too soon for OpenTofu to finish the changes in flight, write its
# state and release its lock. So plan and apply, the commands that lock the
# state, run apart from the step (tofu_session.py, in a session of its own)
# and the step only watches them. On a cancel:
#   - this step sends OpenTofu ONE interrupt, its graceful stop: it finishes
#     what it is changing, writes the state, releases the lock and exits.
#     Never two: a second interrupt makes it exit at once.
#   - the workflow's `if: cancelled()` step runs --stop, which sends that
#     interrupt if this step didn't get to, and waits for OpenTofu to end.
#     A lock left behind is removed only when it is this runner's and no
#     OpenTofu is running (the workflow's concurrency group means no other
#     run can hold it).
# init and output run in the step as before: init takes no lock, and output
# only reads.
set -euo pipefail

runs="${RUNNER_TEMP:-/tmp}/tofu-runs"
here=$(cd "$(dirname "$0")" && pwd)

alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

# interrupt <run dir>: OpenTofu's one interrupt, at most once whoever asks
# (mkdir is the once).
interrupt() {
  local run=$1
  mkdir "$run/interrupted" 2>/dev/null || return 0
  if alive "$run/tofu.pid"; then
    kill -INT "$(cat "$run/tofu.pid")" 2>/dev/null || true
    echo "Asked OpenTofu ($(cat "$run/what")) to stop gracefully."
  fi
}

# follow <run dir>: show OpenTofu's output until it ends. Sets rc.
follow() {
  local run=$1 tail_pid
  tail -n +1 -F "$run/log" 2>/dev/null &
  tail_pid=$!
  # Until it writes its exit code, or its session is gone without one.
  while [ ! -f "$run/rc" ]; do
    if [ -f "$run/session.pid" ] && ! alive "$run/session.pid" && [ ! -f "$run/rc" ]; then
      break
    fi
    sleep 2
  done
  sleep 2   # tail -F's last read
  kill "$tail_pid" 2>/dev/null || true
  wait "$tail_pid" 2>/dev/null || true
  rc=$(cat "$run/rc" 2>/dev/null || echo 1)
}

# ---------------------------------------------------------------- --stop
if [ "${1:-}" = --stop ]; then
  shopt -s nullglob
  found=0
  for run in "$runs"/*/; do
    run=${run%/}
    [ -f "$run/rc" ] && continue
    found=1
    interrupt "$run"
    echo "Waiting for OpenTofu ($(cat "$run/what")) to finish and release its lock..."
    follow "$run"
    echo "OpenTofu ($(cat "$run/what")) ended with exit code $rc."
    echo "Stopped gracefully: $(cat "$run/what"), exit code $rc. Re-run the create to continue from here." >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  done
  [ "$found" = 1 ] || echo "No OpenTofu command was running."

  # A lock left behind (OpenTofu killed after all): remove it if it is this
  # runner's and nothing is running. Each state once (plan and apply share
  # one).
  declare -A checked=()
  for run in "$runs"/*/; do
    run=${run%/}
    [ -f "$run/lock" ] || continue
    read -r bucket key dir < "$run/lock"
    alive "$run/tofu.pid" && continue
    [ -z "${checked[$key]:-}" ] || continue
    checked[$key]=1
    lock=$(aws s3 cp "s3://$bucket/$key.tflock" - 2>/dev/null || true)
    [ -n "$lock" ] || continue
    who=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("Who",""))' "$lock")
    id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("ID",""))' "$lock")
    if [ "${who#*@}" = "$(uname -n)" ] && [ -n "$id" ]; then
      echo "Removing the lock this runner left on $key ($id)."
      tofu -chdir="$dir" force-unlock -force "$id"
      echo "Removed a leftover state lock on \`$key\`." >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
    else
      echo "::warning::$key is locked by $who, not this runner; left as it is."
    fi
  done
  exit 0
fi

# ---------------------------------------------------------------- a stage
stage="$1" account="$2" cluster="$3" bucket="$4" region="$5" mode="$6" tfvars="$7"
dir="${STAGE_DIR:-tofu/create-cluster/$stage}"
[ -d "$dir" ] || { echo "::error::No stage $stage ($dir)"; exit 1; }
case "$mode" in plan|apply) ;; *) echo "::error::mode must be plan or apply"; exit 1 ;; esac

cp "$tfvars" "$dir/create.auto.tfvars.json"
key="accounts/$account/clusters/$cluster/$stage.tfstate"

# tofu_run <what> <tofu args...>: one locking command, apart from the step.
# Sets rc.
run=""
tofu_run() {
  local what=$1; shift
  mkdir -p "$runs"
  run=$(mktemp -d "$runs/$stage.XXXXXX")
  echo "$what" > "$run/what"
  echo "$bucket $key $dir" > "$run/lock"
  : > "$run/log"
  setsid --fork python3 "$here/tofu_session.py" "$run" "$@" < /dev/null
  follow "$run"
  run=""
}

# GitHub's cancel: one interrupt to OpenTofu, then leave the waiting to the
# workflow's `if: cancelled()` step (--stop).
on_cancel() {
  trap - INT TERM
  if [ -n "$run" ]; then
    interrupt "$run"
    echo "::warning::Cancelled during $(cat "$run/what"): OpenTofu is stopping gracefully; the next step waits for it."
  fi
  exit 130
}
trap on_cancel INT TERM

echo "::group::tofu init ($key)"
tofu -chdir="$dir" init -input=false -reconfigure \
  -backend-config="bucket=$bucket" \
  -backend-config="key=$key" \
  -backend-config="region=$region"
echo "::endgroup::"

# -detailed-exitcode: 0 no changes, 2 changes, 1 error.
tofu_run "$stage plan" -chdir="$dir" plan -input=false -no-color -detailed-exitcode -out=tfplan
case "$rc" in
  0) echo "$stage: no changes" ;;
  2) echo "$stage: changes planned" ;;
  *) echo "::error::$stage: plan failed"; exit 1 ;;
esac

if [ "$mode" = apply ] && [ "$rc" = 2 ]; then
  tofu_run "$stage apply" -chdir="$dir" apply -input=false -no-color tfplan
  [ "$rc" = 0 ] || { echo "::error::$stage: apply failed (exit code $rc)"; exit 1; }
fi

# Outputs, for the next steps and the cluster's record.
mkdir -p build/create-cluster
tofu -chdir="$dir" output -json > "build/create-cluster/$stage.outputs.json"
