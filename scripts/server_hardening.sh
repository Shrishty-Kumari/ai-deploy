#!/usr/bin/env bash
# One-time VPS hardening script. Run once on a fresh Ubuntu/Debian server
# as root or with sudo, BEFORE exposing it to the internet.
set -euo pipefail

echo "==> Updating system packages"
apt-get update && apt-get upgrade -y

echo "==> Installing UFW, fail2ban, unattended-upgrades"
apt-get install -y ufw fail2ban unattended-upgrades curl

echo "==> Configuring firewall (UFW): deny all inbound except SSH/HTTP/HTTPS"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "==> Configuring fail2ban for SSH brute-force protection"
cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl enable fail2ban
systemctl restart fail2ban

echo "==> Enabling automatic security updates"
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "==> Recommended manual steps (not automated by this script):"
echo "   1. Disable SSH password auth (use keys only): edit /etc/ssh/sshd_config"
echo "      -> PasswordAuthentication no, PermitRootLogin no, then: systemctl restart sshd"
echo "   2. Create a non-root deploy user with sudo + docker group membership."
echo "   3. Install Docker + Docker Compose plugin (see docs/DEPLOYMENT.md)."

echo "==> Done. Firewall status:"
ufw status verbose
