#!/usr/bin/env bash
set -euo pipefail

USER=cluster

if [[ $EUID -ne 0 ]]; then
    echo "Error: Run this script as root (sudo or direct)"
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
if [[ -z "${SSH_KEY}" ]]; then
    echo "Error: SSH_KEY not found in $ENV_FILE"
    exit 1
fi
if [[-z "${TAILSCALE_AUTH_KEY}" ]]; then
    echo "Error: TAILSCALE_AUTH_KEY not found in $ENV_FILE"
    exit 1
fi
if [[ -z "${K3S_HOSTNAME}" ]]; then
    echo "Error: K3S_HOSTNAME not found in $ENV_FILE"
    exit 1
fi
if [[-z "${K3S_NODE_TOKEN}" ]]; then
    echo "Error: K3S_NODE_TOKEN not found in $ENV_FILE"
    exit 1
fi

echo "Setting up Alpine Linux as worker for k3s cluster"
sed -i 's/#http/http/g' /etc/apk/repositories
apk update

# doas setup
echo "Configuring doas"
adduser cluster wheel
# Passwordless doas for wheel group
echo "permit nopass :wheel" >> /etc/doas.d/*.conf

# Tailscale setup
echo "Installing and configuring Tailscale"
apk add tailscale tailscale-openrc
rc-update add tailscale default
rc-service tailscale start

echo "Authenticating Tailscale"
tailscale up --auth-key="$TAILSCALE_AUTH_KEY"

# OpenSSH setup
echo "Installing and configuring OpenSSH"
apk add openssh
rc-update add sshd default
rc-service sshd start

echo "Deploying SSH public key"
mkdir -p "/home/$USER/.ssh"
echo "$SSH_KEY" > "/home/$USER/.ssh/authorized_keys"
chmod 600 "/home/$USER/.ssh/authorized_keys"

# ACPID setup
echo "Installing and cofiguring ACPID"
apk add acpid
rc-update add acpid default
rc-service acpid start
sed -i '/^        power-supply-ac || suspend/s/^/# /' /etc/acpi/handler.sh
rc-service acpid restart

# General package installation for k3s
echo "Installing iptables, cni-plugins, and curl"
apk add iptables cni-plugins curl

# Turn off swap
echo "Disabling swap"
swapoff -a
sed -i '/swap/d' /etc/fstab
rc-service cgroups start
rc-update add cgroups boot

# Add memory params to cgroup
CGROUP_PARAMS="cgroup_enable=memory cgroup_memory=1"
if ! grep -q "cgroup_memory=1" /etc/default/grub; then
    echo "Adding cgroup memory parameters to GRUB"
    sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$CGROUP_PARAMS /" /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg
fi

echo "Completed Alpine Linux setup"

# Install k3s as worker
echo "Installing k3s as worker"
curl -sfL https://get.k3s.io | K3S_URL="https://$K3S_HOSTNAME:6443" \
    sh -s - agent \
    --token "$K3S_NODE_TOKEN"
rc-update add k3s-agent default
rc-service k3s-agent start

echo "k3 worker setup is complete"
