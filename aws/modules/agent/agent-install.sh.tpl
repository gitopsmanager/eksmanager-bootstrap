#!/bin/bash
set -euxo pipefail

# 1. Wait for package manager lock
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
   sleep 5
done

# 2. Preparation (Download/Extract)
apt-get update -yq && apt-get install -y unzip curl
curl -fsSL '${af7_bundle_download_url}' -o /tmp/af7.zip
rm -rf /home/ubuntu/.af7 && unzip -o /tmp/af7.zip -d /home/ubuntu/.af7 && rm /tmp/af7.zip

curl -fsSL '${agent_upgrade_download_url}' -o /tmp/agent_upgrade.zip
rm -rf /home/ubuntu/bin/agent_upgrade.dist && mkdir -p /home/ubuntu/bin
unzip -o /tmp/agent_upgrade.zip -d /home/ubuntu/bin && rm /tmp/agent_upgrade.zip

# 3. Create the Runner Script
# The variables are expanded here, so the script has the hardcoded URLs ready to run.
cat << EOF > /usr/local/bin/agent_upgrade_runner.sh
#!/bin/bash
/home/ubuntu/bin/agent_upgrade.dist/agent_upgrade.bin \
  --download-url '${agent_download_url}' \
  --upload-url '${agent_upload_url}'
EOF
chmod +x /usr/local/bin/agent_upgrade_runner.sh

# 4. Create the Systemd Service
# This is now simple and clean
cat << EOF > /etc/systemd/system/agent_install.service
[Unit]
Description=Run Agent Upgrade Installer Once
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/bin/agent_upgrade_runner.sh
ExecStartPost=/usr/bin/systemctl disable agent_install.service

[Install]
WantedBy=multi-user.target
EOF

# 5. Enable and Start
systemctl daemon-reload
systemctl enable agent_install.service
systemctl start --no-block agent_install.service

echo "=== EKS Manager Agent Preparation Complete. Installer is running in background. ==="
