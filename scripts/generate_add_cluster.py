#!/usr/bin/env python3
# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
"""
Generates everything CodeBuild needs for a single add-cluster run:
  <output_dir>/buildspec.yml               -- one build (no batch section --
                                               always exactly one cluster)
  <output_dir>/terraform/add-cluster/       -- copy of the module
  <output_dir>/terraform/add-cluster/cluster.auto.tfvars.json
                                             -- this cluster's account,
                                               region, expanded prefix
                                               list names, and SG IDs

The buildspec's `finally` block reports success/failure back to the EKS
Manager API regardless of how the apply went (CODEBUILD_BUILD_SUCCEEDING),
using the same M2M credential pattern eksmanager-bootstrap already uses.

Usage:
  python3 generate_add_cluster.py \
    --cluster-name cluster1 \
    --clusters clusters.json \
    --prefix-lists prefix-lists.json \
    --state-bucket eksmanager-prefix-lists-905418220450 \
    --state-region eu-west-1 \
    --output-dir build/add-cluster
"""
import argparse
from pathlib import Path

from common import load_json, stage_module, validate_account_id, write_json

BUILDSPEC_TEMPLATE = """version: 0.2

env:
  variables:
    TARGET_ACCOUNT: "{account_id}"
    TARGET_REGION: "{region}"
    CLUSTER_NAME: "{cluster_name}"
  secrets-manager:
    EKSMANAGER_CLIENT_SECRET: "/EKSManagerBootstrap/client-m2m-cognito-secret"

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
      - cd add-cluster
      - |
        terraform init -input=false \\
          -backend-config="bucket={state_bucket}" \\
          -backend-config="region={state_region}" \\
          -backend-config="key=accounts/${{TARGET_ACCOUNT}}/clusters/${{CLUSTER_NAME}}/terraform.tfstate"
      - terraform apply -input=false -auto-approve -var="target_account_id=${{TARGET_ACCOUNT}}" -var="target_region=${{TARGET_REGION}}" -var="cluster_name=${{CLUSTER_NAME}}"
    finally:
      - |
        if [ "$CODEBUILD_BUILD_SUCCEEDING" = "1" ]; then STATUS="success"; else STATUS="failed"; fi
      - |
        TOKEN=$(curl -fsSL -X POST "${{EKSMANAGER_COGNITO_URL}}/oauth2/token" \\
          -H "Content-Type: application/x-www-form-urlencoded" \\
          -d "grant_type=client_credentials&client_id=${{EKSMANAGER_CLIENT_ID}}&client_secret=${{EKSMANAGER_CLIENT_SECRET}}" \\
          | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)
      - |
        curl -s -X POST "${{EKSMANAGER_API_URL}}/clusters/${{CLUSTER_NAME}}/prefix-list-status" \\
          -H "Authorization: Bearer ${{TOKEN}}" \\
          -H "Content-Type: application/json" \\
          -d "{{\\"status\\": \\"${{STATUS}}\\"}}"
"""


def expand_group(group_name, groups):
    if group_name not in groups:
        raise SystemExit(
            f"ERROR: group '{group_name}' not found in prefix-lists.json's 'groups' -- "
            f"available groups: {sorted(groups.keys())}"
        )
    return groups[group_name]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cluster-name", required=True, help="Which cluster in clusters.json to build for -- one build, one cluster, never a loop")
    parser.add_argument("--clusters", required=True, help="Path to clusters.json")
    parser.add_argument("--prefix-lists", required=True, help="Path to prefix-lists.json (for the groups -> granular-names expansion)")
    parser.add_argument("--state-bucket", required=True)
    parser.add_argument("--state-region", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument(
        "--module-src",
        default=str(Path(__file__).resolve().parent.parent / "terraform" / "add-cluster"),
        help="Path to the terraform/add-cluster module to stage (default: ../terraform/add-cluster relative to this script)",
    )
    args = parser.parse_args()

    clusters = load_json(args.clusters)
    prefix_lists = load_json(args.prefix_lists)

    if args.cluster_name not in clusters:
        raise SystemExit(
            f"ERROR: '{args.cluster_name}' not found in {args.clusters} -- "
            f"available clusters: {sorted(clusters.keys())}"
        )
    cluster = clusters[args.cluster_name]

    for required_key in ("account", "region", "group", "sg_ids"):
        if required_key not in cluster:
            raise SystemExit(f"ERROR: clusters.json['{args.cluster_name}'] is missing '{required_key}'")

    validate_account_id(cluster["account"], f"clusters.json[{args.cluster_name}].account")

    if not cluster["sg_ids"]:
        raise SystemExit(f"ERROR: clusters.json['{args.cluster_name}'].sg_ids is empty -- need at least one security group ID")

    groups = prefix_lists.get("groups", {})
    prefix_list_names = expand_group(cluster["group"], groups)
    print(f"Cluster '{args.cluster_name}': group '{cluster['group']}' -> {prefix_list_names}")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    buildspec = BUILDSPEC_TEMPLATE.format(
        account_id=cluster["account"],
        region=cluster["region"],
        cluster_name=args.cluster_name,
        state_bucket=args.state_bucket,
        state_region=args.state_region,
    )
    (output_dir / "buildspec.yml").write_text(buildspec)
    print(f"Wrote {output_dir / 'buildspec.yml'}")

    stage_module(args.module_src, output_dir, "add-cluster")
    write_json(
        output_dir / "add-cluster" / "cluster.auto.tfvars.json",
        {
            "target_account_id": cluster["account"],
            "target_region": cluster["region"],
            "cluster_name": args.cluster_name,
            "prefix_list_names": prefix_list_names,
            "sg_ids": cluster["sg_ids"],
        },
    )
    print(f"Staged add-cluster/ (module + cluster.auto.tfvars.json) into {output_dir}")


if __name__ == "__main__":
    main()
