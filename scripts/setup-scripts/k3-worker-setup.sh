#!/bin/sh
set -euo pipefail

USER=cluster

chmod +x setup-base.sh
./setup-base.sh

# Rexecute as bash
if [ -z "${BASH_VERSION}" ]; then
    exec bash "$0" "$@"
fi

if [[ $EUID -ne 0 ]]; then
    echo "Error: Run this script as root (doas or direct with su -)"
    exit 1
fi

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

# Setup Longhorn
echo "Setting up Longhorn"
cat << 'EOF' | doas tee /etc/local.d/longhorn-mounts.start > /dev/null
#!/bin/sh

mkdir -p /var/lib/longhorn

if ! mountpoint -q /var/lib/longhorn; then
    mount --bind /var/lib/longhorn /var/lib/longhorn
fi

mount --make-shared /var/lib/longhorn

if mountpoint -q /mnt/ssd-storage; then
    mount --make-shared /mnt/ssd-storage
fi

if mountpoint -q /mnt/hdd-storage; then
    mount --make-shared /mnt/hdd-storage
fi
EOF

doas chmod +x /etc/local.d/longhorn-mounts.start
doas rc-update add local default
doas /etc/local.d/longhorn-mounts.start

# Install k3s as worker
echo "Installing k3s as worker"
curl -sfL https://get.k3s.io | K3S_URL="https://$K3S_SERVER_IP:6443" \
    sh -s - agent \
    --token "$K3S_NODE_TOKEN"
rc-update add k3s-agent default
rc-service k3s-agent start

echo "k3 worker setup is complete"
