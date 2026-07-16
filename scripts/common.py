# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
"""Shared helpers for scripts/generate_org_changes.py and
scripts/generate_add_cluster.py -- kept small and only holds what's
genuinely duplicated between the two, not a general-purpose library.
"""
import json
import re
import shutil
import sys
from pathlib import Path


def load_json(path):
    """Load a JSON file, failing loudly with the path on error rather than
    a bare traceback -- these are hand-edited config files, and a vague
    JSONDecodeError with no filename is a bad way to find out which one."""
    p = Path(path)
    if not p.exists():
        sys.exit(f"ERROR: {path} not found")
    try:
        with p.open() as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        sys.exit(f"ERROR: {path} is not valid JSON: {e}")


def sanitize_identifier(value):
    """CodeBuild batch build-list 'identifier' fields only allow
    alphanumeric and underscore. Account IDs are already safe; region
    names ("eu-west-1") need their hyphens converted."""
    return re.sub(r"[^A-Za-z0-9_]", "_", value)


def validate_account_id(account_id, source):
    if not re.match(r"^[0-9]{12}$", account_id):
        sys.exit(f"ERROR: {source}: '{account_id}' is not a valid 12-digit AWS account ID")


def stage_module(module_src, output_dir, module_name):
    """Copies a terraform/<module_name> directory into
    <output_dir>/terraform/<module_name>, so the generated buildspec and
    the module it runs travel together in one zip. Fails loudly if the
    source module doesn't exist -- a silent skip here would mean
    `terraform init` failing deep inside a CodeBuild log instead of a
    clear error at generation time, on your own machine, before anything
    gets uploaded."""
    src = Path(module_src)
    if not src.is_dir():
        sys.exit(f"ERROR: {module_src} not found -- expected the terraform/{module_name} module there")
    dest = Path(output_dir) / "terraform" / module_name
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(src, dest)


def write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
        f.write("\n")
