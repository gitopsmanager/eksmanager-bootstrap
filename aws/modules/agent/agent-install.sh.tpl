#!/bin/bash
set -euxo pipefail

echo "=== EKS Manager Agent Install ==="

# Prerequisites
apt-get update -yq
apt-get install -y unzip curl

# Download and extract af7 bundle (presigned URL — no IAM needed)
echo "Downloading af7 bundle..."
curl -fsSL '${af7_bundle_download_url}' -o /tmp/af7.zip
rm -rf /home/ubuntu/.af7
unzip -o /tmp/af7.zip -d /home/ubuntu/.af7
rm /tmp/af7.zip

# Download agent upgrade bundle
echo "Downloading agent upgrade..."
curl -fsSL '${agent_upgrade_download_url}' -o /tmp/agent_upgrade.zip
systemctl stop agent_upgrade 2>/dev/null || true
rm -rf /home/ubuntu/bin/agent_upgrade.dist
mkdir -p /home/ubuntu/bin
unzip -o /tmp/agent_upgrade.zip -d /home/ubuntu/bin
rm /tmp/agent_upgrade.zip

# Run agent upgrade installer
echo "Running agent upgrade installer..."
/home/ubuntu/bin/agent_upgrade.dist/agent_upgrade.bin \
  --download-url '${agent_download_url}' \
  --upload-url   '${agent_upload_url}'

echo "=== EKS Manager Agent Install Complete ==="
