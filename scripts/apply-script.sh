#!/bin/sh
set -euo pipefail

NODES=("cluster@node-gk1", "cluster@node-envy", "cluster@node-zen", "cluster@node-envy700", "cluster@node-xps")

SCRIPT_TO_RUN="scripts/fix-scripts/usb-ethernet-fix.sh"

echo "Getting key"
eval "$(ssh-agent -s)" > /dev/null
ssh-add ~/.ssh/id_ed25519

for node in "${NODES[@]}"; do
    echo "Executing on $node"
    ssh -o StrictHostKeyChecking=accept-new "$node" 'doas bash -s' < "$SCRIPT_TO_RUN"
done

echo "Done, cleaning ssh agent"
ssh-agent -k /dev/null
