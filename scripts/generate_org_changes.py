#!/usr/bin/env python3
# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
"""
Generates everything CodeBuild needs for an org-changes run:
  <output_dir>/buildspec.yml               -- one build-list entry per
                                               (account, region) pair
  <output_dir>/terraform/org-changes/       -- copy of the module
  <output_dir>/terraform/org-changes/granular.auto.tfvars.json
                                             -- the granular CIDR data,
                                               auto-loaded by Terraform,
                                               identical for every pair

No dynamic values inside the buildspec itself -- every TARGET_ACCOUNT/
TARGET_REGION pair is a literal, fully-baked-in build-list entry (per the
"no CodeBuild dynamic matrix" decision: that mechanism has a documented
env-var propagation gap, and build-list with literal per-item values is
the reliable, well-supported path instead).

Usage:
  python3 generate_org_changes.py \
    --topology topology.json \
    --prefix-lists prefix-lists.json \
    --state-bucket eksmanager-prefix-lists-905418220450 \
    --state-region eu-west-1 \
    --output-dir build/org-changes

Test locally before this is ever wired into a GitHub Action: inspect
<output_dir> directly, or cd into <output_dir>/terraform/org-changes and
run `terraform init`/`plan` by hand against one pair's account/region
(passed as -var, since granular.auto.tfvars.json only covers the
granular_lists variable).
"""
import argparse
from pathlib import Path

from common import load_json, sanitize_identifier, stage_module, validate_account_id, write_json

BUILDSPEC_HEADER = """version: 0.2

batch:
  fast-fail: true
  build-list:
"""

BUILDSPEC_PHASES = """
phases:
  install:
    commands:
      - TERRAFORM_VERSION="1.11.0"
      - |
        wget -q -O terraform.zip \\
          "https://releases.hashicorp.com/terraform/${{TERRAFORM_VERSION}}/terraform_${{TERRAFORM_VERSION}}_linux_amd64.zip"
      - unzip -q terraform.zip && mv terraform /usr/local/bin/ && rm terraform.zip

  build:
    commands:
      - cd terraform/org-changes
      - |
        terraform init -input=false \\
          -backend-config="bucket={state_bucket}" \\
          -backend-config="region={state_region}" \\
          -backend-config="key=accounts/${{TARGET_ACCOUNT}}/org-changes/${{TARGET_REGION}}/terraform.tfstate"
      - terraform apply -input=false -auto-approve -var="target_account_id=${{TARGET_ACCOUNT}}" -var="target_region=${{TARGET_REGION}}"
"""


def account_region_pairs(topology):
    """Flattens topology.json's orgConfig (ou -> account -> [regions]) into
    a deduplicated, sorted list of (account, region) pairs. Sorted so
    re-running the generator against unchanged input produces byte-identical
    output -- makes diffs in review meaningful instead of noise from dict
    ordering."""
    pairs = set()
    org_config = topology.get("orgConfig", {})
    for ou_id, accounts in org_config.items():
        for account_id, regions in accounts.items():
            validate_account_id(account_id, f"topology.json orgConfig[{ou_id}]")
            for region in regions:
                pairs.add((account_id, region))
    if not pairs:
        raise SystemExit("ERROR: topology.json's orgConfig has no account/region pairs -- nothing to build")
    return sorted(pairs)


def render_buildspec(pairs, state_bucket, state_region):
    lines = [BUILDSPEC_HEADER]
    for account_id, region in pairs:
        identifier = f"build_{sanitize_identifier(account_id)}_{sanitize_identifier(region)}"
        lines.append(f"    - identifier: {identifier}\n")
        lines.append("      env:\n")
        lines.append("        variables:\n")
        lines.append(f'          TARGET_ACCOUNT: "{account_id}"\n')
        lines.append(f'          TARGET_REGION: "{region}"\n')
    lines.append(BUILDSPEC_PHASES.format(state_bucket=state_bucket, state_region=state_region))
    return "".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--topology", required=True, help="Path to topology.json")
    parser.add_argument("--prefix-lists", required=True, help="Path to prefix-lists.json")
    parser.add_argument("--state-bucket", required=True, help="S3 bucket for Terraform state (eksmanager-prefix-lists-<shared-services-account-id>)")
    parser.add_argument("--state-region", required=True, help="Region the state bucket lives in")
    parser.add_argument("--output-dir", required=True, help="Directory to stage buildspec.yml + terraform/org-changes/ into")
    parser.add_argument(
        "--module-src",
        default=str(Path(__file__).resolve().parent.parent / "terraform" / "org-changes"),
        help="Path to the terraform/org-changes module to stage (default: ../terraform/org-changes relative to this script)",
    )
    args = parser.parse_args()

    topology = load_json(args.topology)
    prefix_lists = load_json(args.prefix_lists)

    if "granular" not in prefix_lists:
        raise SystemExit(f"ERROR: {args.prefix_lists} has no top-level 'granular' key")

    pairs = account_region_pairs(topology)
    print(f"Found {len(pairs)} (account, region) pair(s):")
    for account_id, region in pairs:
        print(f"  {account_id} / {region}")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    buildspec = render_buildspec(pairs, args.state_bucket, args.state_region)
    (output_dir / "buildspec.yml").write_text(buildspec)
    print(f"Wrote {output_dir / 'buildspec.yml'}")

    stage_module(args.module_src, output_dir, "org-changes")
    write_json(
        output_dir / "terraform" / "org-changes" / "granular.auto.tfvars.json",
        {"granular_lists": prefix_lists["granular"]},
    )
    print(f"Staged terraform/org-changes/ (module + granular.auto.tfvars.json) into {output_dir}")


if __name__ == "__main__":
    main()
