#!/usr/bin/env bash
set -euo pipefail

# Solo-Stack VPS Bootstrap
# Run once on a fresh Ubuntu 24.04 VPS as root.

# --- System updates ---
apt update && apt upgrade -y

# --- Install Docker ---
curl -fsSL https://get.docker.com | sh
systemctl enable docker

# --- Add deploy user ---
useradd -m -s /bin/bash deploy
usermod -aG docker deploy

# --- Install Tailscale (optional, for secure SSH from CI) ---
# Uncomment if you want Tailscale for CI/CD access:
# curl -fsSL https://tailscale.com/install.sh | sh
# tailscale up --auth-key=tskey-auth-XXXXX

# --- Create the shared proxy network ---
docker network create proxy || true

# --- Create project directory ---
mkdir -p /opt/solo-stack
chown deploy:deploy /opt/solo-stack

# --- Firewall ---
apt install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp   # SSH (or Tailscale port)
ufw allow 80/tcp   # HTTP  (Caddy)
ufw allow 443/tcp  # HTTPS (Caddy)
ufw --force enable

echo "VPS bootstrap complete. Next steps:"
echo "  1. Clone your repo into /opt/solo-stack"
echo "  2. Copy .env.example files to .env and fill in real values"
echo "  3. Start Caddy: cd /opt/solo-stack/caddy && docker compose up -d"
