cat << 'EOF' > /usr/local/bin/check-flannel-loop.sh
#!/bin/sh
while true; do
    if ! ip link show flannel.1 >/dev/null 2>&1; then
        if ip link show eth0 >/dev/null 2>&1; then
            logger "flannel.1 missing but eth0 is back, restarting k3s-agent"
            rc-service k3s-agent restart
            sleep 10
        else
            logger "flannel.1 missing and eth0 is also missing, waiting for hardware"
            sleep 5
        fi
    fi
    sleep 1
done
EOF

chmod +x /usr/local/bin/check-flannel-loop.sh

cat << 'EOF' > /etc/init.d/flannel-watchdog
#!/sbin/openrc-run

command="/usr/local/bin/check-flannel-loop.sh"
command_background="yes"
pidfile="/run/flannel-watchdog.pid"

depend() {
    need net
    after k3s-agent
}
EOF

chmod +x /etc/init.d/flannel-watchdog

rc-update add flannel-watchdog default 2>/dev/null

rc-service flannel-watchdog restart 2>/dev/null || rc-service flannel-watchdog start

echo "Flannel watchdog installed and running."
