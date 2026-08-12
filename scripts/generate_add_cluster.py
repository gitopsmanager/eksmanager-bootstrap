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
                                               list names, SG IDs, and DNS
                                               zone prefix

The buildspec's `finally` block reports success/failure back to the EKS
Manager API regardless of how the apply went (CODEBUILD_BUILD_SUCCEEDING),
using the same M2M credential pattern eksmanager-bootstrap already uses.

Usage:
  python3 generate_add_cluster.py \
    --cluster-name cluster1 \
    --clusters clusters.json \
    --prefix-groups prefix-groups.json \
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
      # ONE command, deliberately. Each CodeBuild `commands:` entry runs in
      # its own shell -- AWS documents this, and terraform/lets-encrypt's
      # buildspec works around the same trap for its tfvars. Split across
      # three entries, STATUS and TOKEN both arrive empty here: the callback
      # posts {{"status": ""}} with a bare "Authorization: Bearer", so a failed
      # apply is never reported as failed. That is silent -- the build log
      # shows all three commands running and nothing looks wrong.
      - |
        if [ "$CODEBUILD_BUILD_SUCCEEDING" = "1" ]; then STATUS="success"; else STATUS="failed"; fi
        echo "Reporting ${{STATUS}} for ${{CLUSTER_NAME}}."

        TOKEN=$(curl -fsSL -X POST "${{EKSMANAGER_COGNITO_URL}}/oauth2/token" \\
          -H "Content-Type: application/x-www-form-urlencoded" \\
          -d "grant_type=client_credentials&client_id=${{EKSMANAGER_CLIENT_ID}}&client_secret=${{EKSMANAGER_CLIENT_SECRET}}" \\
          | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

        if [ -z "${{TOKEN}}" ]; then
          echo "WARNING: no access token -- cannot report ${{STATUS}} for ${{CLUSTER_NAME}}." >&2
          exit 0
        fi

        # Reports the HTTP code and body rather than failing on them. This
        # block is telemetry: the build's outcome is the terraform apply above,
        # and a rejected callback must not turn a cluster whose rules ARE in
        # place into a red build -- that is worse than the silence it replaced,
        # because it is wrong in the confident direction.
        #
        # Not `curl -f` for the same reason: -f exits 22 and prints nothing
        # useful, so a 401 and a 404 look identical. Capturing the code names
        # which one it is.
        HTTP=$(curl -sS -o /tmp/callback-body.txt -w '%{{http_code}}' \\
          -X POST "${{EKSMANAGER_API_URL}}/clusters/${{CLUSTER_NAME}}/prefix-list-status" \\
          -H "Authorization: Bearer ${{TOKEN}}" \\
          -H "Content-Type: application/json" \\
          -d "{{\\"status\\": \\"${{STATUS}}\\"}}" || echo "000")

        case "${{HTTP}}" in
          2*) echo "Reported ${{STATUS}} for ${{CLUSTER_NAME}} (HTTP ${{HTTP}})." ;;
          000) echo "WARNING: status callback could not reach ${{EKSMANAGER_API_URL}}." >&2 ;;
          *)
            echo "WARNING: status callback rejected -- HTTP ${{HTTP}}." >&2
            echo "  POST ${{EKSMANAGER_API_URL}}/clusters/${{CLUSTER_NAME}}/prefix-list-status" >&2
            sed -n '1,20p' /tmp/callback-body.txt >&2
            echo "  The apply result above stands; only the report failed." >&2
            ;;
        esac
        exit 0
"""


def expand_environment(environment, prefix_groups):
    """
    Map an environment name to the prefix lists it allows in.

    prefix-groups.json is a flat list so both concepts are named rather than
    positional:

        [ { "environment": "dev", "prefix-lists": ["corp_vpn"] } ]

    The lists themselves are not created or managed here -- they must already
    exist in the target account and region, and terraform/add-cluster resolves
    them by name.
    """
    known = {}
    for entry in prefix_groups:
        name = (entry.get("environment") or "").strip()
        if name:
            known[name] = entry.get("prefix-lists") or []

    if environment not in known:
        raise SystemExit(
            f"ERROR: environment '{environment}' not found in prefix-groups.json -- "
            f"available environments: {sorted(known)}"
        )
    return known[environment]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cluster-name", required=True, help="Which cluster in clusters.json to build for -- one build, one cluster, never a loop")
    parser.add_argument("--clusters", required=True, help="Path to clusters.json")
    parser.add_argument("--prefix-groups", required=True, help="Path to prefix-groups.json (environment -> prefix list names)")
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
    prefix_groups = load_json(args.prefix_groups)

    if args.cluster_name not in clusters:
        raise SystemExit(
            f"ERROR: '{args.cluster_name}' not found in {args.clusters} -- "
            f"available clusters: {sorted(clusters.keys())}"
        )
    cluster = clusters[args.cluster_name]

    for required_key in ("account", "region", "environment"):
        if required_key not in cluster:
            raise SystemExit(f"ERROR: clusters.json['{args.cluster_name}'] is missing '{required_key}'")

    validate_account_id(cluster["account"], f"clusters.json[{args.cluster_name}].account")

    # The two groups take different rules -- the EKS group only needs the API
    # server port, the NLB group needs every port Traefik fronts -- so they are
    # listed separately rather than as one sg_ids list. Entries written before
    # that split are read as EKS groups, which is the conservative reading: it
    # grants 443 rather than opening every port on a group that may not want it.
    eks_sg_ids = list(cluster.get("eks_sg_ids", cluster.get("sg_ids", [])))
    nlb_sg_ids = list(cluster.get("nlb_sg_ids", []))

    if "eks_sg_ids" not in cluster and "sg_ids" in cluster:
        print(
            f"NOTE: clusters.json['{args.cluster_name}'] uses the older 'sg_ids' key -- "
            f"treating those as EKS security groups (port {443}). Add 'nlb_sg_ids' to open "
            f"the load balancer's ports."
        )

    if not eks_sg_ids and not nlb_sg_ids:
        raise SystemExit(
            f"ERROR: clusters.json['{args.cluster_name}'] lists no security groups -- "
            f"need at least one of 'eks_sg_ids' or 'nlb_sg_ids'"
        )

    prefix_list_names = expand_environment(cluster["environment"], prefix_groups)
    print(f"Cluster '{args.cluster_name}': environment '{cluster['environment']}' -> {prefix_list_names}")

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
            "eks_sg_ids": eks_sg_ids,
            "nlb_sg_ids": nlb_sg_ids,
            # Tags the rules Environment=<prefix>, matching what the agent put
            # on the cluster itself. Optional and defaulted: entries written
            # before dns_zone_prefix existed simply omit the tag rather than
            # failing a build over a cost-reporting field.
            "dns_zone_prefix": cluster.get("dns_zone_prefix", ""),
        },
    )
    print(f"Staged add-cluster/ (module + cluster.auto.tfvars.json) into {output_dir}")


if __name__ == "__main__":
    main()
