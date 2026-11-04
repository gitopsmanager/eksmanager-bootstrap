#!/usr/bin/env python3
# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
"""
Steps of bootstrap-create-cluster.yml that are not OpenTofu.

    prepare       validate clusters/<name>.json, resolve its zone from
                  hosted-zones.json, write the variables every stage reads
    addon-report  check every EKS add-on is ACTIVE, healthy and the newest
                  compatible version; write the run summary table
    register      record the cluster for the add-cluster network pipeline
                  (clusters.json) and write clusters/<name>.outputs.json

Standard library only: the runner image has Python but nothing is installed
into it per run.
"""
import argparse
import ipaddress
import json
import os
import re
import subprocess
import sys

ALLOW_ALL = "allow all"   # BootstrapPrefixLists.AllowAll: no prefix-list rules

NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,99}$")
REGION_RE = re.compile(r"^[a-z]{2}(-[a-z]+)+-[0-9]$")
VERSION_RE = re.compile(r"^1\.[0-9]{2}$")
SUBNET_RE = re.compile(r"^subnet-[0-9a-f]{8,17}$")
INSTANCE_RE = re.compile(r"^[a-z0-9]+\.[a-z0-9]+$")
NS_RE = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
ROLE_ARN_RE = re.compile(r"^arn:aws:iam::[0-9]{12}:role/.+$")

SPEC_KEYS = {"name", "zone_prefix", "region", "kubernetes_version", "prefix_list_group",
             "network", "node_pools", "global_namespaces"}


def fail(msg):
    print(f"::error::{msg}")
    sys.exit(1)


def load_json(path, what):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        fail(f"{what} not found: {path}")
    except json.JSONDecodeError as e:
        fail(f"{what} is not valid JSON ({path}): {e}")


def gh_output(**kv):
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as f:
        for k, v in kv.items():
            f.write(f"{k}={v}\n")


def gh_summary(text):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text + "\n")
    print(text)


# ---------------------------------------------------------------- prepare

def validate_pool(name, pool, errors):
    if not isinstance(pool, dict):
        errors.append(f"node_pools.{name} must be an object")
        return
    extra = set(pool) - {"instance_type", "count", "disk_size"}
    if extra:
        errors.append(f"node_pools.{name}: unknown keys {sorted(extra)}")
    if not INSTANCE_RE.match(str(pool.get("instance_type", ""))):
        errors.append(f"node_pools.{name}.instance_type is not an instance type: {pool.get('instance_type')!r}")
    c = pool.get("count")
    if not isinstance(c, int) or isinstance(c, bool) or not 1 <= c <= 100:
        errors.append(f"node_pools.{name}.count must be an integer 1-100")
    d = pool.get("disk_size")
    if not isinstance(d, int) or isinstance(d, bool) or not 20 <= d <= 16384:
        errors.append(f"node_pools.{name}.disk_size must be an integer 20-16384 (GiB)")


def validate_spec(spec, file_stem):
    """The rules of clusters/cluster.schema.json, enforced without jsonschema."""
    errors = []
    if not isinstance(spec, dict):
        fail("The cluster file must be a JSON object")
    extra = set(spec) - SPEC_KEYS
    if extra:
        errors.append(f"unknown keys {sorted(extra)}")
    for k in ("name", "zone_prefix", "region", "kubernetes_version", "prefix_list_group", "network", "node_pools"):
        if k not in spec:
            errors.append(f"{k} is required")
    name = spec.get("name", "")
    if not NAME_RE.match(str(name)):
        errors.append(f"name must be lowercase letters, digits and hyphens, starting with a letter: {name!r}")
    if name != file_stem:
        errors.append(f"name {name!r} must match the file name ({file_stem}.json)")
    if not REGION_RE.match(str(spec.get("region", ""))):
        errors.append(f"region is not an AWS region: {spec.get('region')!r}")
    if not VERSION_RE.match(str(spec.get("kubernetes_version", ""))):
        errors.append(f"kubernetes_version must be a minor version like 1.36: {spec.get('kubernetes_version')!r}")

    net = spec.get("network") or {}
    if not isinstance(net, dict):
        errors.append("network must be an object")
        net = {}
    extra = set(net) - {"subnet_ids", "service_cidr"}
    if extra:
        errors.append(f"network: unknown keys {sorted(extra)}")
    subnets = net.get("subnet_ids")
    if not isinstance(subnets, list) or len(subnets) < 2:
        errors.append("network.subnet_ids needs at least two subnets (one per availability zone)")
    else:
        bad = [s for s in subnets if not SUBNET_RE.match(str(s))]
        if bad:
            errors.append(f"network.subnet_ids are not subnet ids: {bad}")
        if len(set(subnets)) != len(subnets):
            errors.append("network.subnet_ids has duplicates")
    cidr = net.get("service_cidr", "10.244.0.0/24")
    try:
        ipaddress.ip_network(cidr)
    except ValueError:
        errors.append(f"network.service_cidr is not a CIDR: {cidr!r}")

    pools = spec.get("node_pools") or {}
    if not isinstance(pools, dict):
        errors.append("node_pools must be an object")
        pools = {}
    extra = set(pools) - {"system", "general"}
    if extra:
        errors.append(f"node_pools: unknown pools {sorted(extra)}; other pools come from the GUI, not the create")
    for p in ("system", "general"):
        if p not in pools:
            errors.append(f"node_pools.{p} is required")
        else:
            validate_pool(p, pools[p], errors)

    ns = spec.get("global_namespaces", [])
    if not isinstance(ns, list) or any(not NS_RE.match(str(n)) for n in ns):
        errors.append("global_namespaces must be a list of namespace names")
    elif len(set(ns)) != len(ns):
        errors.append("global_namespaces has duplicates")

    if errors:
        for e in errors:
            print(f"::error::{e}")
        fail(f"{file_stem}.json is not a valid cluster definition ({len(errors)} problem(s))")


def resolve_zone(hosted_zones, prefix):
    zones = hosted_zones.get("hosted-zones") or []
    match = [z for z in zones if z.get("dns-zone-prefix") == prefix]
    if not match:
        fail(f"zone_prefix {prefix!r} is not a dns-zone-prefix in hosted-zones.json")
    if len(match) > 1:
        fail(f"zone_prefix {prefix!r} appears {len(match)} times in hosted-zones.json")
    z = match[0]
    account = str(z.get("account", ""))
    if not re.match(r"^[0-9]{12}$", account):
        fail(f"hosted-zones.json: zone {prefix!r} has no valid account")
    dns_zone = (z.get("private-hosted-zone") or "").rstrip(".")
    if not dns_zone:
        fail(f"hosted-zones.json: zone {prefix!r} has no private-hosted-zone")
    ext_dns = ((z.get("roles") or {}).get("external_dns") or "")
    # EKS Manager never creates the external-dns role: it is the customer's,
    # named in the zone. Refuse rather than build a cluster that cannot
    # publish its own hostnames (same check as the GUI and the agent).
    if not ROLE_ARN_RE.match(ext_dns):
        fail(f"hosted-zones.json: zone {prefix!r} has no roles.external_dns; add it before creating a cluster in it")
    return account, dns_zone, ext_dns


def cmd_prepare(a):
    path = os.path.join(a.clusters_dir, f"{a.cluster}.json")
    if os.path.basename(path).startswith("example-"):
        fail("example-*.json files are examples and are never created")
    spec = load_json(path, "Cluster file")
    validate_spec(spec, a.cluster)

    account, dns_zone, ext_dns = resolve_zone(load_json(a.hosted_zones, "hosted-zones.json"), spec["zone_prefix"])

    group = spec["prefix_list_group"]
    if group.lower() != ALLOW_ALL:
        groups = load_json(a.prefix_groups, "prefix-groups.json")
        # A list of {"environment": ..., "prefix-lists": [...]}, as
        # generate_add_cluster.py reads it.
        envs = {g.get("environment") for g in groups if isinstance(g, dict)} if isinstance(groups, list) else set()
        if group not in envs:
            fail(f"prefix_list_group {group!r} is not an environment in prefix-groups.json (or use {ALLOW_ALL!r})")

    try:
        runtime = json.loads(a.runtime)
    except json.JSONDecodeError as e:
        fail(f"--runtime is not JSON: {e}")
    for k in ("shared_services_account_id", "secrets_region", "runner_subnet_cidr", "admin_role_name", "cd_repo_url"):
        if not runtime.get(k):
            fail(f"runtime value {k} is missing (a repository variable of the workflow)")
    try:
        ipaddress.ip_network(runtime["runner_subnet_cidr"])
    except ValueError:
        fail(f"runner_subnet_cidr is not a CIDR: {runtime['runner_subnet_cidr']!r}")

    cluster = {
        "name": spec["name"],
        "account_id": account,
        "region": spec["region"],
        "kubernetes_version": spec["kubernetes_version"],
        "zone_prefix": spec["zone_prefix"],
        "dns_zone": dns_zone,
        "external_dns_role_arn": ext_dns,
        "prefix_list_group": group,
        "subnet_ids": spec["network"]["subnet_ids"],
        "service_cidr": spec["network"].get("service_cidr", "10.244.0.0/24"),
        "node_pools": spec["node_pools"],
        "global_namespaces": spec.get("global_namespaces", []),
    }
    os.makedirs(a.out, exist_ok=True)
    out = os.path.join(a.out, "create.auto.tfvars.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"cluster": cluster, "runtime": runtime}, f, indent=2)
    print(f"Wrote {out}")
    gh_output(account_id=account, region=spec["region"], dns_zone=dns_zone,
              zone_prefix=spec["zone_prefix"], prefix_list_group=group)
    gh_summary(f"### Create {spec['name']}\n\n| | |\n|---|---|\n"
               f"| Account / region | {account} / {spec['region']} |\n"
               f"| Kubernetes | {spec['kubernetes_version']} |\n"
               f"| Zone | {spec['zone_prefix']} ({dns_zone}) |\n"
               f"| Prefix lists | {group} |\n"
               f"| System pool | {spec['node_pools']['system']['count']} x {spec['node_pools']['system']['instance_type']} |\n"
               f"| General pool | {spec['node_pools']['general']['count']} x {spec['node_pools']['general']['instance_type']} |\n")


# ----------------------------------------------------------- addon-report

def aws(args, env):
    r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True, env=env)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or f"aws {' '.join(args)} failed")
    return json.loads(r.stdout or "{}")


def workload_env(role_arn, region):
    """Credentials for the workload account: the runner's own (here the agent
    role's) session assumes EKSManagerAdminRole, as the stages do."""
    env = dict(os.environ)
    creds = aws(["sts", "assume-role", "--role-arn", role_arn,
                 "--role-session-name", "eksmanager-create-cluster-check"], env)["Credentials"]
    env.update(AWS_ACCESS_KEY_ID=creds["AccessKeyId"], AWS_SECRET_ACCESS_KEY=creds["SecretAccessKey"],
               AWS_SESSION_TOKEN=creds["SessionToken"], AWS_REGION=region, AWS_DEFAULT_REGION=region)
    return env


def cmd_addon_report(a):
    env = workload_env(a.role_arn, a.region)
    cluster = aws(["eks", "describe-cluster", "--name", a.cluster], env)["cluster"]
    k8s = cluster["version"]
    names = aws(["eks", "list-addons", "--cluster-name", a.cluster], env).get("addons", [])
    rows, bad, installed = [], 0, {}
    for name in sorted(names):
        ad = aws(["eks", "describe-addon", "--cluster-name", a.cluster, "--addon-name", name], env)["addon"]
        installed[name] = ad.get("addonVersion")
        versions = aws(["eks", "describe-addon-versions", "--addon-name", name,
                        "--kubernetes-version", k8s], env).get("addons", [])
        # Newest compatible: the first listed, the same choice the agent and
        # the stages' most_recent lookup make.
        newest = versions[0]["addonVersions"][0]["addonVersion"] if versions and versions[0].get("addonVersions") else "?"
        issues = (ad.get("health") or {}).get("issues") or []
        ok = ad.get("status") == "ACTIVE" and not issues and ad.get("addonVersion") == newest
        bad += 0 if ok else 1
        rows.append(f"| {name} | {ad.get('addonVersion')} | {newest} | {ad.get('status')} | "
                    f"{'; '.join(i.get('code', '') + ': ' + i.get('message', '') for i in issues) or 'none'} | "
                    f"{'ok' if ok else '**check**'} |")
    expected = set(a.expected.split(","))
    missing = sorted(expected - set(names))
    gh_summary("\n#### EKS add-ons\n\n| Add-on | Installed | Newest compatible | Status | Health issues | |\n"
               "|---|---|---|---|---|---|\n" + "\n".join(rows))
    if missing:
        gh_summary(f"\n**Missing:** {', '.join(missing)}")
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(installed, f, indent=2)
    if bad or missing:
        fail(f"{bad} add-on(s) not ACTIVE, healthy and newest; {len(missing)} missing")


# --------------------------------------------------------------- register

def cmd_register(a):
    spec = load_json(os.path.join(a.clusters_dir, f"{a.cluster}.json"), "Cluster file")
    outputs = load_json(a.tofu_outputs, "OpenTofu outputs")
    addons = load_json(a.addon_versions, "Add-on versions") if a.addon_versions else {}

    def out(k):
        v = outputs.get(k, {})
        return v.get("value") if isinstance(v, dict) else v

    record = {
        "account_id": a.account_id,
        "region": spec["region"],
        "kubernetes_version": spec["kubernetes_version"],
        "vpc_id": out("vpc_id"),
        "subnet_ids": out("subnet_ids"),
        "cluster_security_group_id": out("cluster_security_group_id"),
        "nlb_security_group_id": out("nlb_security_group_id"),
        "aws_lbc_webhook_ca_pem": out("aws_lbc_webhook_ca_pem"),
        "addon_versions": addons,
    }
    path = os.path.join(a.clusters_dir, f"{a.cluster}.outputs.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(record, f, indent=2)
        f.write("\n")
    print(f"Wrote {path}")

    # clusters.json is what add-cluster-network.yml reads: the same entry the
    # server's BootstrapClusterRegistry writes for an agent-built cluster.
    group = spec["prefix_list_group"]
    if group.lower() == ALLOW_ALL:
        print(f"prefix_list_group is {ALLOW_ALL!r}: no prefix-list rules, clusters.json not changed")
        gh_output(register_network="false")
        return
    reg = load_json(a.clusters_json, "clusters.json") if os.path.exists(a.clusters_json) else {}
    reg[a.cluster] = {
        "account": a.account_id,
        "region": spec["region"],
        "environment": group,
        "eks_sg_ids": [out("cluster_security_group_id")],
        "nlb_sg_ids": [out("nlb_security_group_id")],
        "dns_zone_prefix": spec["zone_prefix"],
    }
    with open(a.clusters_json, "w", encoding="utf-8") as f:
        json.dump(reg, f, indent=2)
        f.write("\n")
    print(f"Recorded {a.cluster} in {a.clusters_json}")
    gh_output(register_network="true")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("prepare")
    s.add_argument("--cluster", required=True)
    s.add_argument("--clusters-dir", default="clusters")
    s.add_argument("--hosted-zones", default="hosted-zones.json")
    s.add_argument("--prefix-groups", default="prefix-groups.json")
    s.add_argument("--runtime", required=True, help="JSON object of values from the workflow")
    s.add_argument("--out", default="build/create-cluster")
    s.set_defaults(fn=cmd_prepare)

    s = sub.add_parser("addon-report")
    s.add_argument("--cluster", required=True)
    s.add_argument("--region", required=True)
    s.add_argument("--role-arn", required=True)
    s.add_argument("--expected", required=True, help="comma-separated add-on names that must exist")
    s.add_argument("--out", default="build/create-cluster/addon-versions.json")
    s.set_defaults(fn=cmd_addon_report)


    s = sub.add_parser("register")
    s.add_argument("--cluster", required=True)
    s.add_argument("--account-id", required=True)
    s.add_argument("--clusters-dir", default="clusters")
    s.add_argument("--clusters-json", default="clusters.json")
    s.add_argument("--tofu-outputs", required=True)
    s.add_argument("--addon-versions", default="")
    s.set_defaults(fn=cmd_register)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
