#!/usr/bin/env bash
#
# Back up Open WebUI data with the app stopped (offline backup).
#
# Usage: ./backup.sh [statefulset-name]      (default: open-webui)
#
# The whole data directory of the stopped application - webui.db with any
# SQLite WAL/journal sidecars, uploads/, vector_db/, and everything else on
# the data PVC - is archived into a timestamped tar.gz in the current
# directory. Because the app is stopped while we read, a single tar pass is
# a consistent whole-dataset snapshot; no per-database snapshots are taken.
#
# How it works:
#   1. Validate local tools, take the shared lock (backup.sh and restore.sh
#      share one lock so they can never run at the same time).
#   2. Resolve the StatefulSet, its data container's image, and the data
#      PVC from the StatefulSet spec (read-only; works at 0 replicas).
#      Unsupported layouts are rejected: >1 replica, volumeClaimTemplates,
#      or a subPath on the data mount.
#   3. Scale the app to 0 and wait for the pod to terminate on its own.
#      The pod is never force-deleted.
#   4. A temporary helper pod (unique per invocation, app's image) mounts
#      the data PVC; the data dir is streamed out as tar.gz over kubectl
#      exec into a local temp file.
#   5. The local archive is verified (readable, webui.db at the root) and
#      only then promoted to its final name. The temp file is removed on
#      any failure.
#   6. The helper is deleted and the app scaled back to its original
#      replica count (0 stays 0).
#
# Operational artifacts are excluded from the archive and are never deleted
# by this script: owui-staging/ and owui-prev-*/ directories left on the
# PVC by restore.sh. Restore recovery data is preserved across backups.
#
# The stream-out step (tar through kubectl exec) has no transfer checksum;
# the local tar tzf verification is the integrity gate, and a failed backup
# is always safe to re-run because backup never mutates the data dir.
#
# Restore: ./restore.sh <backup.tar.gz> [statefulset-name]

set -euo pipefail

# The archive holds the database and user uploads: keep it private.
umask 077

NS="open-webui"
SET="${1:-open-webui}"
CONTAINER="open-webui"
DATA_MOUNT="/app/backend/data"
DATA_DIR_IN_POD="/data"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="open-webui-backup-$TS.tar.gz"
TMP_OUT="${OUT}.tmp"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK_DIR="$SCRIPT_DIR/.owui-ops.lock"
HELPER="owui-backup-$$"

for tool in kubectl tar date hostname; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: required tool '$tool' not found on this machine" >&2
        exit 1
    fi
done

# --- shared lock: one backup or restore at a time -----------------------
# Atomic mkdir; the owner record lets a future run explain who is holding
# the lock. Stale-lock recovery: if a run dies leaving the lock behind,
# verify no backup/restore is actually in progress, then remove it with:
#   rm -rf "$SCRIPT_DIR/.owui-ops.lock"
LOCK_ACQUIRED=0
REPLICAS=0
scaled_down=0
HELPER_CREATED=0
cleanup() {
    rm -f "$TMP_OUT" 2>/dev/null || true
    if [ "$HELPER_CREATED" -eq 1 ]; then
        kubectl -n "$NS" delete pod "$HELPER" --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true
        kubectl -n "$NS" wait --for=delete pod "$HELPER" --timeout=60s >/dev/null 2>&1 || true
    fi
    # Backup never mutates the data dir, so on failure the app comes back.
    if [ "$scaled_down" -eq 1 ] && [ "$REPLICAS" -gt 0 ]; then
        kubectl -n "$NS" scale statefulset "$SET" --replicas="$REPLICAS" >/dev/null 2>&1 || true
    fi
    if [ "$LOCK_ACQUIRED" -eq 1 ]; then
        rm -f "$LOCK_DIR/owner" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

NOW="$(date +%s)"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    owner="$(cat "$LOCK_DIR/owner" 2>/dev/null || true)"
    echo "Error: another backup or restore is in progress (shared lock is held)." >&2
    echo "  lock: $LOCK_DIR" >&2
    if [ -n "$owner" ]; then
        printf '%s\n' "$owner" | sed 's/^/  /' >&2
    fi
    epoch="$(printf '%s\n' "$owner" | sed -n 's/^epoch=//p' | head -n 1 || true)"
    if [ -n "$epoch" ] && [ $((NOW - epoch)) -gt 7200 ]; then
        echo "" >&2
        echo "The lock is stale ($(((NOW - epoch) / 60)) min old). If no backup/restore" >&2
        echo "is actually in progress, remove it with:" >&2
    else
        echo "" >&2
        echo "If that operation is dead, remove the stale lock with:" >&2
    fi
    echo "  rm -rf $LOCK_DIR" >&2
    exit 1
fi
{
    echo "op=backup"
    echo "statefulset=$SET"
    echo "pid=$$"
    echo "host=$(hostname)"
    echo "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "epoch=$NOW"
} > "$LOCK_DIR/owner"
LOCK_ACQUIRED=1

# --- resolve the deployment (read-only; works at 0 replicas) -----------
if ! kubectl -n "$NS" get statefulset "$SET" >/dev/null 2>&1; then
    echo "Error: statefulset '$SET' not found in namespace $NS" >&2
    exit 1
fi
REPLICAS="$(kubectl -n "$NS" get statefulset "$SET" -o jsonpath='{.spec.replicas}')"
REPLICAS="${REPLICAS:-1}"
case "$REPLICAS" in
    0|1) : ;;
    *)
        echo "Error: $SET has $REPLICAS replicas; only 0 or 1 are supported" >&2
        exit 1
        ;;
esac
if [ -n "$(kubectl -n "$NS" get statefulset "$SET" -o jsonpath='{.spec.volumeClaimTemplates[*].metadata.name}')" ]; then
    echo "Error: $SET uses volumeClaimTemplates; only an explicit-PVC layout is supported" >&2
    exit 1
fi
VOLUME="$(kubectl -n "$NS" get statefulset "$SET" -o jsonpath="{range .spec.template.spec.containers[*].volumeMounts[?(@.mountPath==\"$DATA_MOUNT\")]}{.name}{end}" | tr ' ' '\n' | grep -v '^$' | head -n 1 || true)"
if [ -z "$VOLUME" ]; then
    echo "Error: no container in $SET mounts $DATA_MOUNT" >&2
    exit 1
fi
SUBPATH="$(kubectl -n "$NS" get statefulset "$SET" -o jsonpath="{range .spec.template.spec.containers[?(@.name==\"$CONTAINER\")].volumeMounts[?(@.mountPath==\"$DATA_MOUNT\")]}{.subPath}{end}" | tr ' ' '\n' | grep -v '^$' | head -n 1 || true)"
if [ -n "$SUBPATH" ]; then
    echo "Error: the $DATA_MOUNT mount in $SET uses subPath=$SUBPATH; unsupported" >&2
    exit 1
fi
PVC="$(kubectl -n "$NS" get statefulset "$SET" -o jsonpath="{range .spec.template.spec.volumes[?(@.name==\"$VOLUME\")].persistentVolumeClaim.claimName}{end}")"
if [ -z "$PVC" ]; then
    echo "Error: volume '$VOLUME' in $SET is not backed by a PVC" >&2
    exit 1
fi
IMAGE="$(kubectl -n "$NS" get statefulset "$SET" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$CONTAINER\")].image}")"
case "$IMAGE" in
    "" | '['* | *[[:space:]]* )
        echo "Error: could not read a single image for container '$CONTAINER' from $SET" >&2
        exit 1
        ;;
esac

echo "Namespace:   $NS"
echo "StatefulSet: $SET (was $REPLICAS replica(s))"
echo "Image:       $IMAGE"
echo "PVC:         $PVC"
echo "Output:      $(pwd)/$OUT"
echo ""

# --- scale down and wait for the pod to terminate -----------------------
POD="$SET-0"
if [ "$REPLICAS" -gt 0 ]; then
    echo "Scaling $SET to 0 replicas..."
    kubectl -n "$NS" scale statefulset "$SET" --replicas=0
    scaled_down=1
    if kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1; then
        if ! kubectl -n "$NS" wait --for=delete pod "$POD" --timeout=120s; then
            echo "Error: pod $POD did not terminate within 120s after scale-down. It is not force-deleted." >&2
            echo "Check: kubectl -n $NS describe pod $POD" >&2
            exit 1
        fi
    fi
else
    echo "$SET is already at 0 replicas."
fi

# --- helper pod mounting the data PVC ----------------------------------
echo "Creating helper pod $HELPER..."
kubectl -n "$NS" run "$HELPER" --restart=Never \
    --image="$IMAGE" \
    --overrides="{
      \"spec\": {
        \"containers\": [{
          \"name\": \"$HELPER\",
          \"image\": \"$IMAGE\",
          \"command\": [\"sleep\", \"infinity\"],
          \"volumeMounts\": [{\"name\": \"data\", \"mountPath\": \"$DATA_DIR_IN_POD\"}]
        }],
        \"volumes\": [{\"name\": \"data\", \"persistentVolumeClaim\": {\"claimName\": \"$PVC\"}}]
      }
    }"
HELPER_CREATED=1
# Reusing the app's image does not by itself guarantee the helper can pull
# it (image-pull secrets, node cache); the Ready wait below is the real check.
if ! kubectl -n "$NS" wait --for=condition=Ready pod "$HELPER" --timeout=300s; then
    echo "Error: helper pod $HELPER not Ready within 300s (image pull or scheduling problem)." >&2
    echo "Check: kubectl -n $NS describe pod $HELPER" >&2
    exit 1
fi

# --- stream the stopped data dir out as tar.gz --------------------------
echo "Streaming data dir from $PVC..."
if ! kubectl -n "$NS" exec "$HELPER" -- sh -c '
    set -e
    cd "$1"
    if [ ! -f webui.db ]; then
        echo "Error: webui.db not found in $1; the data dir is empty or was never initialized" >&2
        exit 1
    fi
    # Explicit top-level entry list: the reserved restore artifacts are
    # skipped by name, so nothing depends on tar --exclude pattern matching.
    set --
    for e in * .[!.]* ..?*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        case "$e" in
            owui-staging | owui-prev-*) continue ;;
        esac
        set -- "$@" "$e"
    done
    tar -czf - "$@"
' _ "$DATA_DIR_IN_POD" > "$TMP_OUT"; then
    echo "Error: streaming the data dir out of the helper failed" >&2
    exit 1
fi

# --- verify before promoting --------------------------------------------
echo "Verifying archive..."
tar_list="$(tar tzf "$TMP_OUT")"
if ! grep -qE '^(\./)?webui\.db$' <<< "$tar_list"; then
    echo "Error: webui.db missing from the archive root; refusing to ship the archive" >&2
    exit 1
fi
echo "Archive members: $(printf '%s\n' "$tar_list" | grep -c . || true)"

mv "$TMP_OUT" "$OUT"

# --- teardown: helper down, app back up ---------------------------------
kubectl -n "$NS" delete pod "$HELPER" --grace-period=0
HELPER_CREATED=0
kubectl -n "$NS" wait --for=delete pod "$HELPER" --timeout=60s >/dev/null 2>&1 || true
if [ "$REPLICAS" -gt 0 ]; then
    echo "Scaling $SET back to $REPLICAS replica(s)..."
    kubectl -n "$NS" scale statefulset "$SET" --replicas="$REPLICAS"
    scaled_down=0
    if ! kubectl -n "$NS" wait --for=condition=Ready pod "$POD" --timeout=300s; then
        # The archive is complete and verified; the app failing to come up
        # is a separate problem the operator should see, not a failed backup.
        echo "Warning: pod $POD not Ready within 300s after scale-up. The backup itself succeeded ($(pwd)/$OUT)." >&2
        echo "Check: kubectl -n $NS logs $POD" >&2
    fi
else
    echo "$SET was at 0 replicas at the start and is left at 0."
fi
echo "Backup complete: $(pwd)/$OUT"
