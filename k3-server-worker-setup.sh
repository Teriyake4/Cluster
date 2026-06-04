#!/bin/sh
set -euo pipefail

USER=cluster

if [[ $EUID -ne 0 ]]; then
    echo "Error: Run this script as root (doas or direct with su -)"
    exit 1
fi

chmod +x setup-base.sh
./setup-base.sh

ENV_FILE=".env"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: .env file not found."
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

# Validate keys
if [[ -z "${K3S_SERVER_IP}" ]]; then
    echo "Error: K3S_SERVER_IP not found in $ENV_FILE"
    exit 1
fi
if [[ -z "${K3S_NODE_TOKEN}" ]]; then
    echo "Error: K3S_NODE_TOKEN not found in $ENV_FILE"
    exit 1
fi

# Install k3s as worker
echo "Installing k3s as server and worker"
curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_NODE_TOKEN" \
    K3S_NODE_TAINT="node-role.kubernetes.io/control-plane:NoSchedule-" \
    sh -s - server \
    --server "https://$K3S_SERVER_IP:6443"
rc-update add k3s default
rc-service k3s start

# Enable kubectl for normal users
chown "$USER:$USER" "/etc/rancher/k3s/k3s.yaml"

echo "k3 server and worker setup is complete"
