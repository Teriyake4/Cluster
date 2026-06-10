#!/bin/sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: Run this script as root (sudo or direct)"
    exit 1
fi

SERVICE_NAME="acpi-gpe-fix"
SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"
GPE_FILE="/sys/firmware/acpi/interrupts/gpe0F"

if [[ -f "$GPE_FILE" ]]; then
    echo "Disabling acpi gpe0F"
    if [[ "$(cat "$GPE_FILE" | grep -c disable)" -eq 0 ]]; then
        echo disable > "$GPE_FILE"
    else
        echo "gpe0F already disabled. Skipping fix"
    fi
else
    echo "Warning: $GPE_FILE not found"
fi

cat > "$SERVICE_FILE" << 'EOF'
#!/sbin/openrc-run
name="acpi-gpe-fix"
description="Disable ACPI GPE0F interrupt to prevent high CPU usage"

depend() {
    need mountsys
    after bootmisc
}

start() {
    ebegin "Disabling ACPI GPE0F interrupt"
    # Wait for sysfs to be ready (race condition protection)
    while [ ! -f /sys/firmware/acpi/interrupts/gpe0F ]; do
        sleep 1
    done
    echo disable > /sys/firmware/acpi/interrupts/gpe0F
    eend $?
}

stop() {
    einfo "ACPI fix is a boot-only action, nothing to stop"
}

status() {
    einfo "ACPI GPE0F fix applied at boot"
}
EOF

chmod +x "$SERVICE_FILE"
rc-update add "$SERVICE_NAME" boot 2>/dev/null || true

echo "Disabled gpe0F."
echo "To verify run: grep disable /sys/firmware/acpi/interrupts/gpe0F"
echo "Should show as disabled"
