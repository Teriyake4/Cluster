#!/usr/bin/env bash
#
# Restore an Open WebUI backup archive (created by backup.sh) into the PVC.
#
# Usage: ./restore.sh <backup.tar.gz> [statefulset-name]
#
# Works for a fresh install (after `kubectl apply -k deployments/open-webui/overlays/<env>`)
# and for an existing install (e.g. undoing a bad update).
#
# The script scales the app down, loads the archive into the PVC via a one-off
# helper pod (reusing the app's own image, so it's guaranteed pullable), swaps
# the database snapshot into place, and scales the app back up. If interrupted,
# the trap deletes the helper pod and restores the previous replica count.
#
# The archive must be a backup.sh archive: webui.db.bak at the archive root
# (plus uploads/ and vector_db/).

set -euo pipefail

NS="open-webui"
DATA_DIR="/app/backend/data"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <backup.tar.gz> [statefulset-name]" >&2
    exit 1
fi

ARCHIVE="$1"
if [ ! -f "$ARCHIVE" ]; then
    echo "Error: archive not found: $ARCHIVE" >&2
    exit 1
fi

# 1. Resolve the statefulset (default "open-webui", otherwise the only one in the namespace)
SET="${2:-}"
if [ -z "$SET" ]; then
    SET="open-webui"
    if ! kubectl -n "$NS" get statefulset "$SET" >/dev/null 2>&1; then
        SET="$(kubectl -n "$NS" get statefulsets -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v '^$' | head -n 1 || true)"
    fi
fi
if ! kubectl -n "$NS" get statefulset "$SET" >/dev/null 2>&1; then
    echo "Error: statefulset '$SET' not found in namespace $NS" >&2
    exit 1
fi

POD="$SET-0"
if ! kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1; then
    echo "Error: pod $POD not found in namespace $NS" >&2
    exit 1
fi
REPLICAS="$(kubectl -n "$NS" get statefulset "$SET" -o jsonpath='{.spec.replicas}')"

# 2. Resolve the PVC backing the data dir from the pod spec (works even if the pod is Pending)
VOLUME="$(kubectl -n "$NS" get pod "$POD" -o jsonpath="{range .spec.containers[*].volumeMounts[?(@.mountPath==\"$DATA_DIR\")]}{.name}{end}" | tr ' ' '\n' | grep -v '^$' | head -n 1 || true)"
if [ -z "$VOLUME" ]; then
    echo "Error: pod $POD has no volume mounted at $DATA_DIR" >&2
    exit 1
fi
PVC="$(kubectl -n "$NS" get pod "$POD" -o jsonpath="{range .spec.volumes[?(@.name==\"$VOLUME\")]}{.persistentVolumeClaim.claimName}{end}")"
if [ -z "$PVC" ]; then
    echo "Error: volume '$VOLUME' in pod $POD is not backed by a PVC" >&2
    exit 1
fi

# Reuse the app's own image so the helper pod is guaranteed pullable on this cluster
IMAGE="$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].image}')"

echo "Namespace:   $NS"
echo "StatefulSet: $SET (was $REPLICAS replica(s))"
echo "Pod:         $POD"
echo "PVC:         $PVC"
echo "Archive:     $ARCHIVE"
echo ""

# 3. Verify the archive before touching the cluster
echo "Verifying archive..."
tar_list="$(tar tzf "$ARCHIVE")"

if ! printf '%s\n' "$tar_list" | grep -q -E '^(\./)?webui\.db\.bak$'; then
    echo "Error: database snapshot (webui.db.bak) missing from archive root" >&2
    exit 1
fi
if printf '%s\n' "$tar_list" | grep -q -E '^(\./)?webui\.db(-wal|-shm|-journal)?$'; then
    echo "Error: live database files found in archive, refusing to restore" >&2
    exit 1
fi

# 4. Scale down (keeping the original replica count for rollback)
echo "Scaling $SET to 0 replicas..."
kubectl -n "$NS" scale statefulset "$SET" --replicas=0
scaled_down=1
if kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1; then
    kubectl -n "$NS" wait --for=delete pod "$POD" --timeout=120s
fi

HELPER="owui-restore"
cleanup() {
    kubectl -n "$NS" delete pod "$HELPER" --ignore-not-found --grace-period=0 >/dev/null 2>&1 || true
    if [ "${scaled_down:-0}" -eq 1 ] && [ "${REPLICAS:-0}" -gt 0 ]; then
        kubectl -n "$NS" scale statefulset "$SET" --replicas="$REPLICAS" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# 5. One-off pod mounting the PVC (also triggers binding for a fresh, unbound PVC)
echo "Creating helper pod $HELPER (image: $IMAGE)..."
kubectl -n "$NS" run "$HELPER" --restart=Never \
    --image="$IMAGE" \
    --overrides="{
  \"spec\": {
    \"containers\": [{
      \"name\": \"$HELPER\",
      \"image\": \"$IMAGE\",
      \"command\": [\"sleep\", \"infinity\"],
      \"volumeMounts\": [{\"name\": \"data\", \"mountPath\": \"/data\"}]
    }],
    \"volumes\": [{\"name\": \"data\", \"persistentVolumeClaim\": {\"claimName\": \"$PVC\"}}]
  }
}"
kubectl -n "$NS" wait --for=condition=Ready pod "$HELPER" --timeout=120s

# 6. Extract the archive into the volume
echo "Extracting archive into $PVC..."
kubectl -n "$NS" exec -i "$HELPER" -- tar -xzf - -C /data < "$ARCHIVE"

# 7. Swap the database snapshot into place (drop stale WAL/SHM, rename .bak files)
kubectl -n "$NS" exec "$HELPER" -- sh -c '
    cd /data
    rm -f webui.db-wal webui.db-shm webui.db-journal
    if [ -f webui.db.bak ]; then mv -f webui.db.bak webui.db; fi
    if [ -f webui.db-wal.bak ]; then mv -f webui.db-wal.bak webui.db-wal; fi
'

# 8. Teardown: remove the helper pod, scale back up, wait for Ready
echo "Cleaning up..."
kubectl -n "$NS" delete pod "$HELPER" --grace-period=0
if [ "$REPLICAS" -gt 0 ]; then
    kubectl -n "$NS" scale statefulset "$SET" --replicas="$REPLICAS"
    scaled_down=0
    kubectl -n "$NS" wait --for=condition=Ready pod "$POD" --timeout=300s
fi

echo "Restore complete: $SET is back at $REPLICAS replica(s)."
