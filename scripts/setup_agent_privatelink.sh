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

SERVICE_NAME=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('endpointServiceName',''))" "$CONNECT_BODY")
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

# ---------------------------------------------------------------------------
# 1. The endpoint. Idempotent -- a re-run finds the existing one.
# ---------------------------------------------------------------------------
ENDPOINT_ID=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
  --filters "Name=service-name,Values=${SERVICE_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'VpcEndpoints[0].VpcEndpointId' --output text 2>/dev/null)

if [[ -z "$ENDPOINT_ID" || "$ENDPOINT_ID" == "None" ]]; then
  # Its own security group, allowing 443 from the VPC. The endpoint is the thing
  # being reached, so this is what admits the agent to it -- distinct from the
  # rule on the SERVER's NLB, which admits this endpoint's ENI to that listener.
  VPC_CIDR=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" \
    --query 'Vpcs[0].CidrBlock' --output text)

  SG_ID=$(aws ec2 create-security-group --region "$REGION" \
    --group-name "eksmanager-privatelink-endpoint" \
    --description "EKS Manager server PrivateLink endpoint" \
    --vpc-id "$VPC_ID" --query 'GroupId' --output text 2>/dev/null) || \
  SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=eksmanager-privatelink-endpoint" "Name=vpc-id,Values=${VPC_ID}" \
    --query 'SecurityGroups[0].GroupId' --output text)

  aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SG_ID" --protocol tcp --port 443 --cidr "$VPC_CIDR" >/dev/null 2>&1 || true

  echo "Creating endpoint in ${SUBNET_ID}..."
  ENDPOINT_ID=$(aws ec2 create-vpc-endpoint --region "$REGION" \
    --vpc-id "$VPC_ID" --vpc-endpoint-type Interface \
    --service-name "$SERVICE_NAME" \
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
# 2. Wait for available. Nothing works before this.
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
# 3. Prove it, without touching DNS.
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
# 4. Only now: the zone and the record, together.
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
