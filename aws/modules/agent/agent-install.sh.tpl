#!/bin/bash
set -euxo pipefail

echo "=== EKS Manager Agent Install Preparation ==="

# 1. Prerequisites
apt-get update -yq
apt-get install -y unzip curl

# 2. Download and extract bundles
curl -fsSL '${af7_bundle_download_url}' -o /tmp/af7.zip
rm -rf /home/ubuntu/.af7
unzip -o /tmp/af7.zip -d /home/ubuntu/.af7
rm /tmp/af7.zip

curl -fsSL '${agent_upgrade_download_url}' -o /tmp/agent_upgrade.zip
rm -rf /home/ubuntu/bin/agent_upgrade.dist
mkdir -p /home/ubuntu/bin
unzip -o /tmp/agent_upgrade.zip -d /home/ubuntu/bin
rm /tmp/agent_upgrade.zip

# 3. Create the Systemd 'Oneshot' Service
# This service runs the installer and automatically disables itself upon success
cat << 'EOF' > /etc/systemd/system/agent_install.service
[Unit]
Description=Run Agent Upgrade Installer Once
After=network.target

[Service]
Type=oneshot
ExecStart=/home/ubuntu/bin/agent_upgrade.dist/agent_upgrade.bin --download-url '${agent_download_url}' --upload-url '${agent_upload_url}'
# Automatically disable the service so it does not run on subsequent reboots
ExecStartPost=/usr/bin/systemctl disable agent_install.service

[Install]
WantedBy=multi-user.target
EOF

# 4. Start the installer in the background
# We use --no-block so systemd starts it, but cloud-init doesn't wait for it to finish
systemctl daemon-reload
systemctl enable agent_install.service
systemctl start --no-block agent_install.service

echo "=== EKS Manager Agent Preparation Complete. Installer is running in background. ==="
