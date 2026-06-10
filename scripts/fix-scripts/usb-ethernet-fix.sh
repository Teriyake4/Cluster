#!/bin/sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: Run this script as root (sudo or direct)"
    exit 1
fi

INTERFACE="eth0"

echo "Applying USB ethernet fix"

if [ -f /sys/module/usbcore/parameters/autosuspend ]; then
    echo -1 > /sys/module/usbcore/parameters/autosuspend
fi

GRUB_FILE="/etc/default/grub"

if grep -q "usbcore.autosuspend=-1" "$GRUB_FILE"; then
    echo "GRUB already configured"
else
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 usbcore.autosuspend=-1"/' "$GRUB_FILE"

    grub-mkconfig -o /boot/grub/grub.cfg
fi

echo "Intstalling and setting up dhcpcd"
apk add dhcpcd

if grep -q "^auto $INTERFACE" /etc/network/interfaces; then
    echo "Removing $INTERFACE from /etc/network/interfaces"
    sed -i "s/^auto $INTERFACE/#auto $INTERFACE/g" /etc/network/interfaces
    sed -i "s/^iface $INTERFACE/#iface $INTERFACE/g" /etc/network/interfaces
else
    echo "$INTERFACE not found in /etc/network/interfaces."
fi

echo "Starting dhcpcd service"
rc-update add dhcpcd default
rc-service networking restart
rc-service dhcpcd restart

echo "Applied USB ethernet fix"
