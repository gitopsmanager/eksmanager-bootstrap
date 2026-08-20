#!/usr/bin/env bash
# Connect the agent to the EKS Manager server over PrivateLink.
#
# Runs in the client's shared services account, after the aws/ module has
# applied, as EKSManagerBootstrapSharedRole.
#
#   1. create the interface endpoint to the server's endpoint service
#   2. wait for it to be available
#   3. PROVE it works, without touching DNS
#   4. only then create the private hosted zone and its record
#
# Step 3 before step 4 is the whole point. A private hosted zone for the server's
# hostname SHADOWS the public name inside this VPC -- so the moment it exists,
# with or without a usable record, the agent stops resolving the server through
# public DNS. Create it before proving the endpoint works and a failed setup
# takes the agent offline, including its route to report that anything is wrong.
#
# The proof uses curl --resolve, which pins the hostname to the endpoint's own
# address for one request. Testing the hostname directly would resolve publicly,
# succeed via Global Accelerator, and tell you nothing about the private path --
# a false pass, immediately before the irreversible step.
#
# Whether this installation uses PrivateLink at all is the SERVER's answer, not
# a local flag: the route replies 501 when it has no endpoint service, and this
# exits quietly. One less thing to keep in step on the client side.
set -uo pipefail

API_URL="${EKSMANAGER_API_URL:-}"
COGNITO_URL="${EKSMANAGER_COGNITO_URL:-}"
CLIENT_ID="${EKSMANAGER_CLIENT_ID:-}"
CLIENT_SECRET="${EKSMANAGER_CLIENT_SECRET:-}"
PINNED="${1:-aws/pinned.auto.tfvars.json}"

if [[ -z "$API_URL" || -z "$COGNITO_URL" || -z "$CLIENT_ID" ]]; then
  echo "No API URL or M2M credentials -- skipping PrivateLink setup."
  exit 0
fi

# Its own token rather than one passed in. CodeBuild runs each entry in the
# buildspec's `commands` list as a separate shell, so a TOKEN set in an earlier
# entry is simply absent here -- and an empty token would make this look like an
# installation without PrivateLink rather than a broken one.
TOKEN_BODY=$(mktemp)
TOKEN_STATUS=$(curl -sS -X POST "${COGNITO_URL}/oauth2/token"   --connect-timeout 10 --max-time 30   -H "Content-Type: application/x-www-form-urlencoded"   -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}"   -o "$TOKEN_BODY" -w '%{http_code}') || TOKEN_STATUS="000"
TOKEN=$(grep -o '"access_token":"[^"]*"' "$TOKEN_BODY" | cut -d'"' -f4)
rm -f "$TOKEN_BODY"

if [[ "$TOKEN_STATUS" != "200" || -z "$TOKEN" ]]; then
  echo "ERROR: could not obtain an M2M token (${TOKEN_STATUS}) -- not attempting PrivateLink setup." >&2
  exit 1
fi

# The server reads this installation's pinned vars, adds the shared services
# account as an allowed principal, opens 443 for the agent subnet's CIDR on its
# NLB security group, and returns the endpoint service name. Nothing is sent:
# a caller that could nominate an account or a network would be a confused
# deputy, since the agent has no permission to change either itself.
echo "Asking the server to permit this installation..."
CONNECT_BODY=$(mktemp)
CONNECT_STATUS=$(curl -sSL -X POST "${API_URL}/config/privatelink/connect"   --connect-timeout 10 --max-time 60   -H "Authorization: Bearer ${TOKEN}"   -H "Content-Type: application/json"   -o "$CONNECT_BODY" -w '%{http_code}') || CONNECT_STATUS="000"

if [[ "$CONNECT_STATUS" == "501" ]]; then
  echo "Server is not configured for PrivateLink -- skipping."
  rm -f "$CONNECT_BODY"; exit 0
fi
if [[ "$CONNECT_STATUS" != "200" ]]; then
  echo "ERROR: privatelink/connect returned ${CONNECT_STATUS}" >&2
  cat "$CONNECT_BODY" >&2; echo >&2
  rm -f "$CONNECT_BODY"
  exit 1
fi

read -r SERVICE_NAME SERVICE_REGION <<<"$(python3 - "$CONNECT_BODY" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("endpointServiceName", ""), d.get("endpointServiceRegion", ""))
PY
)"
rm -f "$CONNECT_BODY"
if [[ -z "$SERVICE_NAME" ]]; then
  echo "ERROR: the server did not return an endpoint service name." >&2
  exit 1
fi

read -r VPC_ID SUBNET_ID REGION <<<"$(python3 - "$PINNED" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get("vpc_id", ""), d.get("agent_subnet_id", ""), d.get("shared_services_region", ""))
PY
)"

# The hostname to shadow, taken from the API URL rather than configured
# separately: https://demo.example.com/api -> demo.example.com
HOST=$(printf '%s' "$API_URL" | sed -E 's#^https?://##; s#/.*$##; s#:.*$##')

if [[ -z "$VPC_ID" || -z "$SUBNET_ID" || -z "$REGION" || -z "$HOST" ]]; then
  echo "ERROR: missing vpc_id, agent_subnet_id, region or API host -- cannot set up PrivateLink." >&2
  exit 1
fi

echo "PrivateLink: service=${SERVICE_NAME} host=${HOST} subnet=${SUBNET_ID}"

# The endpoint is always built in OUR region; the service may be in another. AWS
# needs telling explicitly when they differ -- an interface endpoint is regional,
# and without --service-region it looks for the service locally and reports a
# service that plainly exists as not existing.
#
# The server enables our region on its side before returning, so by the time we
# get here the cross-region path is open. Older servers return no region at all,
# in which case same-region is the only thing that ever worked anyway.
SVC_REGION_ARGS=()
if [[ -n "$SERVICE_REGION" && "$SERVICE_REGION" != "$REGION" ]]; then
  SVC_REGION_ARGS=(--service-region "$SERVICE_REGION")
  echo "  cross-region: endpoint in ${REGION}, service in ${SERVICE_REGION}"
fi

# ---------------------------------------------------------------------------
# 1. The endpoint's security group, and its one rule.
#
# Asserted on EVERY run, not only when the endpoint is created. These used to
# live inside the creation branch, which meant a run that created the endpoint
# but failed to open it left a state no later run could repair: the endpoint
# exists, so the branch is skipped, so the rule is never added. The endpoint
# reports itself "available" throughout and accepts nothing.
#
# This group admits the agent TO the endpoint. It is a different thing from the
# rule on the SERVER's NLB, which admits this VPC's traffic to that listener.
# ---------------------------------------------------------------------------
VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" \
  --query 'Vpcs[0].CidrBlock' --output text 2>/dev/null) || VPC_CIDR=""
if [[ -z "$VPC_CIDR" || "$VPC_CIDR" == "None" ]]; then
  echo "ERROR: could not read the CIDR of ${VPC_ID}; refusing to guess." >&2
  exit 1
fi

# Look for an existing group BEFORE trying to create one. The other order hid a
# real failure: create was denied, its stderr went to /dev/null, the describe
# found nothing because the group had never been made, and SG_ID became the
# literal string "None" -- which surfaced three calls later as "Invalid Security
# Group Id: 'None'", pointing at the endpoint rather than at the missing
# permission that actually caused it.
SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=eksmanager-privatelink-endpoint" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
  SG_ERR=$(mktemp)
  SG_ID=$(aws ec2 create-security-group --region "$REGION" \
    --group-name "eksmanager-privatelink-endpoint" \
    --description "EKS Manager server PrivateLink endpoint" \
    --vpc-id "$VPC_ID" --query 'GroupId' --output text 2>"$SG_ERR")
  if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    echo "ERROR: could not create the endpoint security group in ${VPC_ID}:" >&2
    cat "$SG_ERR" >&2
    rm -f "$SG_ERR"
    exit 1
  fi
  rm -f "$SG_ERR"
fi
echo "  endpoint security group: ${SG_ID}"

# A duplicate rule is the expected outcome on a re-run and must not fail the
# build. Everything else must: with no ingress the endpoint accepts nothing,
# which looks exactly like a server-side fault and sends you looking in the
# wrong region.
SG_RULE_ERR=$(mktemp)
if ! aws ec2 authorize-security-group-ingress --region "$REGION" \
     --group-id "$SG_ID" --protocol tcp --port 443 --cidr "$VPC_CIDR" \
     >/dev/null 2>"$SG_RULE_ERR"; then
  if ! grep -q "InvalidPermission.Duplicate" "$SG_RULE_ERR"; then
    echo "ERROR: could not permit 443 from ${VPC_CIDR} on ${SG_ID}:" >&2
    cat "$SG_RULE_ERR" >&2
    rm -f "$SG_RULE_ERR"
    exit 1
  fi
fi
rm -f "$SG_RULE_ERR"
echo "  443 permitted from ${VPC_CIDR} on ${SG_ID}"

# ---------------------------------------------------------------------------
# 2. The endpoint. Idempotent -- a re-run finds the existing one.
# ---------------------------------------------------------------------------
ENDPOINT_ID=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
  --filters "Name=service-name,Values=${SERVICE_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>/dev/null)

if [[ -z "$ENDPOINT_ID" || "$ENDPOINT_ID" == "None" ]]; then
  # Confirm the service is visible to THIS principal before trying to build
  # against it. CreateVpcEndpoint answers InvalidServiceName both for a name
  # that is wrong and for a real service the caller is not permitted to see --
  # AWS hides existence rather than returning AccessDenied -- so the raw error
  # cannot distinguish "wrong region" from "not an allowed principal".
  #
  # Retried because the server added this account as a principal seconds ago and
  # that is not always effective immediately.
  WHOAMI=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || echo "unknown")
  echo "  creating as account ${WHOAMI} in ${REGION}"

  VISIBLE=""
  for _ in $(seq 1 12); do
    if aws ec2 describe-vpc-endpoint-services --region "$REGION" \
         "${SVC_REGION_ARGS[@]+"${SVC_REGION_ARGS[@]}"}" \
         --service-names "$SERVICE_NAME" >/dev/null 2>&1; then
      VISIBLE="yes"; break
    fi
    sleep 5
  done

  if [[ -z "$VISIBLE" ]]; then
    echo "ERROR: ${SERVICE_NAME} is not visible to account ${WHOAMI} in ${REGION}." >&2
    echo "  Either the region differs from the service's (the name embeds the" >&2
    echo "  service's own region), or ${WHOAMI} was never added as an allowed" >&2
    echo "  principal. Check the server's allowed principals against ${WHOAMI}." >&2
    exit 1
  fi

  echo "Creating endpoint in ${SUBNET_ID}..."
  ENDPOINT_ID=$(aws ec2 create-vpc-endpoint --region "$REGION" \
    --vpc-id "$VPC_ID" --vpc-endpoint-type Interface \
    --service-name "$SERVICE_NAME" \
    "${SVC_REGION_ARGS[@]+"${SVC_REGION_ARGS[@]}"}" \
    --subnet-ids "$SUBNET_ID" --security-group-ids "$SG_ID" \
    --no-private-dns-enabled \
    --query 'VpcEndpoint.VpcEndpointId' --output text) || {
      echo "ERROR: could not create the endpoint. Is this account an allowed principal on ${SERVICE_NAME}?" >&2
      exit 1
    }
fi
echo "  endpoint: ${ENDPOINT_ID}"

# --no-private-dns-enabled above is deliberate: AWS's own private DNS would
# override the hostname before anything has been proven, which is the failure
# this script is arranged to avoid. The zone below is created only after the
# endpoint answers.

# ---------------------------------------------------------------------------
# 3. Wait for available. Nothing works before this.
# ---------------------------------------------------------------------------
for _ in $(seq 1 60); do
  STATE=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
    --vpc-endpoint-ids "$ENDPOINT_ID" --query 'VpcEndpoints[0].State' --output text)
  [[ "$STATE" == "available" ]] && break
  [[ "$STATE" == "failed" || "$STATE" == "rejected" ]] && {
    echo "ERROR: endpoint ${ENDPOINT_ID} is ${STATE}." >&2; exit 1; }
  sleep 10
done
if [[ "$STATE" != "available" ]]; then
  echo "ERROR: endpoint ${ENDPOINT_ID} still ${STATE} after 10 minutes." >&2
  exit 1
fi
echo "  state: available"

# ---------------------------------------------------------------------------
# 4. Prove it, without touching DNS.
# ---------------------------------------------------------------------------
ENI_IP=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
  --vpc-endpoint-ids "$ENDPOINT_ID" \
  --query 'VpcEndpoints[0].NetworkInterfaceIds' --output text | tr '\t' '\n' | head -1 | \
  xargs -I{} aws ec2 describe-network-interfaces --region "$REGION" \
    --network-interface-ids {} --query 'NetworkInterfaces[0].PrivateIpAddress' --output text)

if [[ -z "$ENI_IP" || "$ENI_IP" == "None" ]]; then
  echo "ERROR: could not read the endpoint's address -- not verifying, and not touching DNS." >&2
  exit 1
fi

echo "Verifying https://${HOST}/healthz via ${ENI_IP} (public DNS untouched)..."
if ! curl -sS -m 20 -o /dev/null -w '  HTTP %{http_code}\n' \
     --resolve "${HOST}:443:${ENI_IP}" "https://${HOST}/healthz"; then
  cat >&2 <<EOF

ERROR: the endpoint is available but ${HOST} did not answer through it.

Nothing has been changed in DNS, so the agent still reaches the server over the
public path. Check on the SERVER side that:
  - the NLB has a 443 listener with a healthy target
  - its security group permits 443 from this subnet's CIDR
EOF
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Only now: the zone and the record, together.
# ---------------------------------------------------------------------------
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$HOST" \
  --query "HostedZones[?Name=='${HOST}.' && Config.PrivateZone].Id | [0]" --output text 2>/dev/null)

if [[ -z "$ZONE_ID" || "$ZONE_ID" == "None" ]]; then
  echo "Creating private hosted zone for ${HOST}..."
  ZONE_ID=$(aws route53 create-hosted-zone --name "$HOST" \
    --caller-reference "eksmanager-$(date -u +%Y%m%d%H%M%S)" \
    --hosted-zone-config "Comment=EKS Manager server over PrivateLink,PrivateZone=true" \
    --vpc "VPCRegion=${REGION},VPCId=${VPC_ID}" \
    --query 'HostedZone.Id' --output text) || {
      echo "ERROR: could not create the private hosted zone." >&2; exit 1; }
fi
ZONE_ID=${ZONE_ID##*/}
echo "  zone: ${ZONE_ID}"

# A 60s TTL so the break-glass -- deleting this record, or the zone -- takes
# effect in a minute rather than five.
DNS_NAME=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
  --vpc-endpoint-ids "$ENDPOINT_ID" \
  --query 'VpcEndpoints[0].DnsEntries[0].DnsName' --output text)
HOSTED_ZONE=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
  --vpc-endpoint-ids "$ENDPOINT_ID" \
  --query 'VpcEndpoints[0].DnsEntries[0].HostedZoneId' --output text)

aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" \
  --change-batch "$(cat <<JSON
{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{
  "Name":"${HOST}","Type":"A",
  "AliasTarget":{"HostedZoneId":"${HOSTED_ZONE}","DNSName":"${DNS_NAME}","EvaluateTargetHealth":false}}}]}
JSON
)" >/dev/null || { echo "ERROR: could not write the record." >&2; exit 1; }

echo "  record: ${HOST} -> ${DNS_NAME}"
echo "PrivateLink setup complete. The agent now reaches ${HOST} privately."
echo "To revert: delete the record, then the hosted zone ${ZONE_ID}."
