#!/usr/bin/env bash
# Configure a dedicated Ubuntu 24.04 VPS. Never run this on a shared host.
set -Eeuo pipefail
umask 077

if [[ $EUID -ne 0 ]]; then
  echo "Run bootstrap.sh as root or through passwordless sudo." >&2
  exit 1
fi

ssh_port=${1:-}
if [[ ! $ssh_port =~ ^[1-9][0-9]{0,4}$ ]] || ((ssh_port > 65535)); then
  echo "Expected the actual SSH port (1–65535)." >&2
  exit 1
fi

# shellcheck source=/dev/null
source /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 24.04 ]]; then
  echo "This bootstrap supports a dedicated Ubuntu 24.04 VPS only." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl python3 ufw util-linux

if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  # Stop with instructions instead of removing packages already on the machine.
  for package in docker.io docker-compose docker-compose-v2 podman-docker containerd runc; do
    if [[ $(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true) == installed ]]; then
      echo "Conflicting package '$package' is installed. Use a fresh Ubuntu image or resolve Docker installation first." >&2
      exit 1
    fi
  done

  install -m 0755 -d /etc/apt/keyrings
  curl --fail --silent --show-error --proto '=https' --tlsv1.2 \
    https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod 0644 /etc/apt/keyrings/docker.asc
  architecture=$(dpkg --print-architecture)
  printf '%s\n' \
    "deb [arch=$architecture signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

systemctl enable --now docker
docker info >/dev/null
docker compose version

# Permit SSH before enabling the firewall, including nonstandard SSH ports.
# Docker bypasses UFW for published ports: the Compose file publishes only 80/443.
ufw allow "$ssh_port/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw default deny incoming
ufw default allow outgoing
ufw --force enable

echo "Docker, Compose, and the VPS firewall are ready."
