#!/bin/sh
set -euo pipefail

# List of nodes
NODES=()

# Path to script
SCRIPT_TO_RUN="scripts/fix-scripts/ip-fix.sh"
# Multi line command
COMMAND_TO_RUN=""

echo "Getting key"
eval "$(ssh-agent -s)" > /dev/null
ssh-add ~/.ssh/id_ed25519

for node in "${NODES[@]}"; do
    echo "Executing on $node"
    # ssh -o StrictHostKeyChecking=accept-new "$node" 'doas bash -s' < "$SCRIPT_TO_RUN"
    ssh -o StrictHostKeyChecking=accept-new "$node" bash -c "$COMMAND_TO_RUN"

done

echo "Done, cleaning ssh agent"
ssh-agent -k /dev/null
