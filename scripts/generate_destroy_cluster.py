#!/usr/bin/env python3
# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
"""
Generates everything CodeBuild needs to tear down one cluster's SG rules:
  <output_dir>/buildspec.yml               -- runs `terraform destroy`
                                               against the add-cluster module
  <output_dir>/terraform/add-cluster/       -- copy of the module (same one
                                               add-cluster.yml uses)
  <output_dir>/terraform/add-cluster/cluster.auto.tfvars.json
                                             -- placeholder values for
                                               prefix_list_names/sg_ids;
                                               `terraform destroy` acts on
                                               what's in STATE, not on these
                                               values, but Terraform still
                                               validates variables before it
                                               gets that far, so they need to
                                               be present and pass the
                                               module's own validation
                                               (sg_ids must be non-empty)

Deliberately does NOT read clusters.json -- account_id/region/cluster_name
are supplied directly as arguments. This avoids an ordering dependency: if
the GUI already removed this cluster's entry from clusters.json before
triggering teardown, a generator reading that file would have nothing to
read. Taking the identifying values directly works regardless of whether
clusters.json still has the entry, never had it, or had it removed first.

Usage:
  python3 generate_destroy_cluster.py \
    --account-id 111111111111 \
    --region eu-west-1 \
    --cluster-name cluster1 \
    --state-bucket eksmanager-prefix-lists-905418220450 \
    --state-region eu-west-1 \
    --output-dir build/destroy-cluster
"""
import argparse
from pathlib import Path

from common import stage_module, validate_account_id, write_json

BUILDSPEC_TEMPLATE = """version: 0.2

env:
  variables:
    TARGET_ACCOUNT: "{account_id}"
    TARGET_REGION: "{region}"
    CLUSTER_NAME: "{cluster_name}"

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
      - cd terraform/add-cluster
      - |
        terraform init -input=false \\
          -backend-config="bucket={state_bucket}" \\
          -backend-config="region={state_region}" \\
          -backend-config="key=accounts/${{TARGET_ACCOUNT}}/clusters/${{CLUSTER_NAME}}/terraform.tfstate"
      - terraform destroy -input=false -auto-approve -var="target_account_id=${{TARGET_ACCOUNT}}" -var="target_region=${{TARGET_REGION}}" -var="cluster_name=${{CLUSTER_NAME}}"
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--account-id", required=True, help="12-digit account ID the cluster is/was in")
    parser.add_argument("--region", required=True, help="Region the cluster is/was in")
    parser.add_argument("--cluster-name", required=True, help="Cluster name -- must match what add-cluster.yml originally used, since it determines the state key being destroyed")
    parser.add_argument("--state-bucket", required=True)
    parser.add_argument("--state-region", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument(
        "--module-src",
        default=str(Path(__file__).resolve().parent.parent / "terraform" / "add-cluster"),
        help="Path to the terraform/add-cluster module to stage (same module add-cluster.yml uses -- destroy needs the same resource definitions, just a different terraform command)",
    )
    args = parser.parse_args()

    validate_account_id(args.account_id, "--account-id")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    buildspec = BUILDSPEC_TEMPLATE.format(
        account_id=args.account_id,
        region=args.region,
        cluster_name=args.cluster_name,
        state_bucket=args.state_bucket,
        state_region=args.state_region,
    )
    (output_dir / "buildspec.yml").write_text(buildspec)
    print(f"Wrote {output_dir / 'buildspec.yml'}")

    stage_module(args.module_src, output_dir, "add-cluster")
    write_json(
        output_dir / "terraform" / "add-cluster" / "cluster.auto.tfvars.json",
        {
            "target_account_id": args.account_id,
            "target_region": args.region,
            "cluster_name": args.cluster_name,
            # Placeholders only -- terraform destroy acts on what's in
            # state, not on these values. They exist purely to satisfy the
            # module's own variable validation (sg_ids must be non-empty).
            "prefix_list_names": [],
            "sg_ids": ["sg-00000000000000000"],
        },
    )
    print(f"Staged terraform/add-cluster/ (module + placeholder cluster.auto.tfvars.json) into {output_dir}")
    print("NOTE: this will destroy every resource in that cluster's state file. Confirm account_id/cluster_name are correct before uploading the resulting artifact.")


if __name__ == "__main__":
    main()
