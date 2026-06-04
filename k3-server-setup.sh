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

# Install k3s as server
echo "Installing k3s as server"
curl -sfL https://get.k3s.io | sh -s - server --cluster-init --disable-agent
rc-update add k3s default
rc-service k3s start

echo "tls-san:" >> /etc/rancher/k3s/config.yaml
echo " - $K3S_SERVER_IP" >> /etc/rancher/k3s/config.yaml

rc-service k3s restart

# Enable kubectl for normal users
chown "$USER:$USER" "/etc/rancher/k3s/k3s.yaml"

echo "k3 server setup is complete"
echo "Verify k3s by running: kubectl get nodes"
echo "k3s node token: $(cat /var/lib/rancher/k3s/server/node-token)"
echo "Or run the following command to get the token: cat /var/lib/rancher/k3s/server/node-token"
