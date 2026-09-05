#!/usr/bin/env bash
#
# Back up Open WebUI data (webui.db.bak, uploads/, vector_db/) from the running
# pod into a timestamped tar.gz in the current directory.
#
# Usage: ./backup.sh
#
# Pod name is fixed via the POD variable below.
# Restore:
#   1. Scale the Open WebUI deployment to 0 replicas.
#   2. Extract the archive into the PVC at /app/backend/data.
#   3. CRITICAL: Remove any existing 'webui.db-wal' and 'webui.db-shm' on the PVC.
#   4. Rename 'webui.db.bak' -> 'webui.db' (and 'webui.db-wal.bak' -> 'webui.db-wal'
#      if the archive contains it, i.e. a snapshot taken by the cp fallback).
#   5. Scale the deployment back to 1 replica.

set -euo pipefail

NS="open-webui"
POD="open-webui-0"
DATA_DIR="/app/backend/data"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="open-webui-backup-$TS.tar.gz"
TMP_OUT="${OUT}.tmp"

# 1. Sanity-check the pod
if ! kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1; then
    echo "Error: pod $POD not found in namespace $NS" >&2
    exit 1
fi

# Prefer a container named "open-webui"; fall back to the pod's first container
CONTAINER="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[*].name}' | tr ' ' '\n' | grep '^open-webui$' || kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].name}')"

echo "Target pod: $NS/$POD (container: $CONTAINER)"

# 2. Clean up the remote snapshot and any local partial archive on exit/failure
cleanup() {
    kubectl -n "$NS" exec "$POD" -c "$CONTAINER" -- rm -f "$DATA_DIR/webui.db.bak" "$DATA_DIR/webui.db-wal.bak" 2>/dev/null || true
    rm -f "$TMP_OUT" 2>/dev/null || true
}
trap cleanup EXIT

# 3. Create a consistent SQLite snapshot inside the pod
echo "Creating database snapshot..."
kubectl -n "$NS" exec "$POD" -c "$CONTAINER" -- sh -c '
    db="$1/webui.db"
    if [ ! -f "$db" ]; then
        echo "Error: $db not found in container filesystem" >&2
        exit 1
    fi
    rm -f "$db.bak" "$db-wal.bak"
    py="$(command -v python3 || command -v python || true)"
    if [ -n "$py" ]; then
        "$py" -c "import sqlite3,sys; a=sqlite3.connect(sys.argv[1], timeout=60); b=sqlite3.connect(sys.argv[1]+\".bak\"); a.backup(b); b.close(); a.close()" "$db"
    elif command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$db" ".backup $db.bak"
    else
        cp "$db" "$db.bak"
        [ -f "$db-wal" ] && cp "$db-wal" "$db-wal.bak" || true
    fi
' _ "$DATA_DIR"

# 4. Stream tar archive to a temporary file
#    GNU tar exits 1 if a file changes while being archived (vector_db/ can be
#    written to by a live instance); step 5's content verification is the real
#    gate, so tolerate that exit code with a warning.
echo "Streaming archive to $OUT..."
set +e
kubectl -n "$NS" exec "$POD" -c "$CONTAINER" -- \
    tar \
        --warning=no-file-changed \
        --exclude='./cache' \
        --exclude='./audit.log' \
        --exclude='./webui.db' \
        --exclude='./webui.db-wal' \
        --exclude='./webui.db-shm' \
        --exclude='./webui.db-journal' \
        -czf - -C "$DATA_DIR" . > "$TMP_OUT"
status=$?
set -e

if [ "$status" -gt 1 ]; then
    echo "Error: tar streaming failed with exit code $status" >&2
    exit 1
fi
if [ "$status" -eq 1 ]; then
    echo "Warning: files were modified during archiving (exit code 1 tolerated)" >&2
fi

# 5. Verify the archive integrity and content boundaries
echo "Verifying backup contents..."
tar_list="$(tar tzf "$TMP_OUT")"

if ! printf '%s\n' "$tar_list" | grep -q -E '^(\./)?webui\.db\.bak$'; then
    echo "Error: database snapshot missing from archive root" >&2
    exit 1
fi

if printf '%s\n' "$tar_list" | grep -q -E '^(\./)?webui\.db(-wal|-shm|-journal)?$'; then
    echo "Error: live database files leaked into archive" >&2
    exit 1
fi

# Promote the verified archive to its final name
mv "$TMP_OUT" "$OUT"
echo "Backup complete and verified: $(pwd)/$OUT"
