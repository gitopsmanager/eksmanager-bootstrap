#!/bin/bash
set -euxo pipefail

# 1. Make apt wait for the dpkg lock instead of failing.
#
# There was a bare `while fuser ... lock-frontend; do sleep 5; done` here, and it
# was not enough, because it is check-then-act: the loop only proves the lock was
# free at the moment it exited. On 30 Aug 2026 the loop passed, `apt-get update`
# ran, and unattended-upgrades took the lock back before `apt-get install` --
# which failed with "Could not get lock /var/lib/dpkg/lock-frontend", aborted
# this script under `set -e` at its first real command, and left the instance
# running with no agent and no /home/ubuntu/.af7 on it. Terraform reported
# success throughout: it waits for the instance to reach RUNNING and never sees
# cloud-init fail.
#
# DPkg::Lock::Timeout makes apt wait at the moment it actually takes the lock, so
# no window exists between the check and the use. Written as apt config rather
# than a flag on each call so that it also covers apt invocations made by
# installers we do not control later in provisioning -- the same file and value
# install_agent_template.sh and setup_agent_services.sh already write.
mkdir -p /etc/apt/apt.conf.d
echo 'DPkg::Lock::Timeout "600";' > /etc/apt/apt.conf.d/99-af7-apt-lock-timeout

# The apt lists lock that `apt-get update` takes is NOT covered by
# DPkg::Lock::Timeout, so wait for that one explicitly -- and say what is being
# waited on, so a slow boot reads as waiting rather than as hanging.
waited=0
while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
   if [ "$waited" -ge 600 ]; then
      echo "[WARN] apt/dpkg lock still held after $waited s - proceeding; DPkg::Lock::Timeout still applies"
      break
   fi
   echo "[INFO] waiting for apt/dpkg lock... ($waited s)"
   sleep 5
   waited=$((waited + 5))
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
