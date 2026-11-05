#!/usr/bin/env bash
#
# Restore an Open WebUI backup archive (created by backup.sh) into the PVC.
#
# Usage: ./restore.sh <backup.tar.gz> [statefulset-name]
#
# The archive must be in the offline format: webui.db (a regular file) at
# the archive root plus the rest of the data dir exactly as it was on the
# PVC, including any SQLite WAL/journal sidecars.
#
# How it works:
#   1. The archive is fully validated locally - readable, correct format,
#      no absolute paths / '..' traversal / reserved restore-artifact
#      names, webui.db a regular file - BEFORE any cluster change.
#   2. Take the shared lock, resolve the StatefulSet / image / data PVC
#      from its spec, scale the app to 0 and wait for the pod to
#      terminate on its own (never force-deleted).
#   3. A temporary helper pod (unique per invocation, app's image) mounts
#      the data PVC. The archive is extracted into a staging dir
#      (owui-staging/) on the PVC.
#   4. The staged webui.db is checked (regular, non-symlink file) and
#      validated with the image's own Python (PRAGMA quick_check) BEFORE
#      the live data is touched.
#   5. Only then is the live data replaced, not merged: the current data
#      dir contents are moved into a fresh mktemp-named owui-prev-*/ dir,
#      the staged contents are moved in, and the staging dir is removed.
#      This is a sequence of renames on the same volume - NOT atomic. An
#      interruption can leave the data split between the two directories.
#   6. On success the helper is deleted and the app scaled back up. A run
#      that started at 0 replicas leaves it at 0 and prints the scale-up
#      command.
#
# Failure policy:
#   - Before the live-data replacement starts, a failure leaves the data
#     dir untouched and the app is scaled back up by the exit trap.
#   - From the start of the replacement until it completes, any failure or
#     interruption leaves the app at 0 replicas. The previous data dir is
#     preserved on the PVC and its exact path is printed.
#   - "Retry" means re-running this script with the same archive: it
#     preserves the current state in a NEW owui-prev-* dir and re-applies
#     the archive. Repeated retries do NOT reconstruct the original
#     dataset - the first owui-prev-* dir is the only copy of it.
#   - "Roll back" means moving the preserved owui-prev-* contents back to
#     the data root. Exact commands are printed when it is relevant.
#
# The archive member checks above catch accidental path problems; they are
# NOT comprehensive protection against a maliciously crafted archive. Only
# restore backups you trust.
#
# Lock: shared with backup.sh via .owui-ops.lock next to this script. If a
# run dies leaving the lock behind, verify no operation is in progress and
# remove it with: rm -rf <scripts>/.owui-ops.lock

set -euo pipefail

umask 077

NS="open-webui"
CONTAINER="open-webui"
DATA_MOUNT="/app/backend/data"
DATA_DIR_IN_POD="/data"
STAGING_IN_POD="/data/owui-staging"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <backup.tar.gz> [statefulset-name]" >&2
    exit 1
fi
ARCHIVE="$1"
SET="${2:-open-webui}"
if [ ! -f "$ARCHIVE" ]; then
    echo "Error: archive not found: $ARCHIVE" >&2
    exit 1
fi

# --- validate the archive locally, before touching the cluster ----------
echo "Verifying archive: $ARCHIVE"
if ! tar_list="$(tar tzf "$ARCHIVE" 2>/dev/null)"; then
    echo "Error: cannot read '$ARCHIVE' as a tar.gz archive" >&2
    exit 1
fi
if grep -qE '^(\./)?webui\.db\.bak$' <<< "$tar_list"; then
    echo "Error: '$ARCHIVE' is an old-format (online snapshot) backup: it" >&2
    echo "contains webui.db.bak instead of webui.db. This script only" >&2
    echo "restores offline backups (webui.db directly). Restore it with the" >&2
    echo "old restore procedure, or convert the archive separately." >&2
    exit 1
fi
if ! grep -qE '^(\./)?webui\.db$' <<< "$tar_list"; then
    echo "Error: webui.db missing from the archive root; not a valid Open WebUI backup" >&2
    exit 1
fi
# Reserved restore-artifact names, absolute paths, and '..' traversal.
# These greps catch accidents; they are not a full tar security boundary.
if grep -qE '^(\./)?owui-staging(/|$)' <<< "$tar_list" || grep -qE '^(\./)?owui-prev-[^/]*(/|$)' <<< "$tar_list"; then
    echo "Error: archive contains restore-reserved entries (owui-staging, owui-prev-*); refusing" >&2
    exit 1
fi
if grep -qE '^/' <<< "$tar_list" || grep -qE '(^|/)\.\.(/|$)' <<< "$tar_list"; then
    echo "Error: archive contains absolute paths or '..' traversal; refusing" >&2
    exit 1
fi
# webui.db must be a regular file: the member type is the first character
# of a 'tar tvf' line ('-' regular, 'l' symlink, 'd' directory, ...).
tar_meta="$(tar tvf "$ARCHIVE")"
db_meta="$(grep -E ' (webui\.db|\.\/webui\.db)$' <<< "$tar_meta" | head -n 1 || true)"
case "$db_meta" in
    -*) : ;;
    *)
        echo "Error: webui.db in the archive is not a regular file (symlink or directory); refusing" >&2
        exit 1
        ;;
esac
has_chroma=""
if grep -qE '^(\./)?vector_db/chroma\.sqlite3$' <<< "$tar_list"; then
    has_chroma=yes
fi
echo "Archive OK: $(printf '%s\n' "$tar_list" | grep -c . || true) members"
echo ""

# --- shared lock: one backup or restore at a time -----------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK_DIR="$SCRIPT_DIR/.owui-ops.lock"
HELPER="owui-restore-$$"
LOCK_ACQUIRED=0
REPLICAS=0
scaled_down=0
HELPER_CREATED=0
# pre-replacement: failure may scale the app back up (data untouched).
# replacing:       any failure leaves the app at 0 replicas.
phase="pre-replacement"
cleanup() {
    if [ "$HELPER_CREATED" -eq 1 ]; then
        # Pre-replacement, the staging dir is ours to clear. While
        # replacing, touch nothing on the PVC except deleting the helper.
        if [ "$phase" = "pre-replacement" ]; then
            kubectl -n "$NS" exec "$HELPER" -- sh -c 'rm -rf "$1"' _ "$STAGING_IN_POD" >/dev/null 2>&1 || true
        fi
        kubectl -n "$NS" delete pod "$HELPER" --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true
        kubectl -n "$NS" wait --for=delete pod "$HELPER" --timeout=60s >/dev/null 2>&1 || true
    fi
    if [ "$phase" = "pre-replacement" ] && [ "$scaled_down" -eq 1 ] && [ "$REPLICAS" -gt 0 ]; then
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
    echo "op=restore"
    echo "statefulset=$SET"
    echo "archive=$ARCHIVE"
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
echo ""

# Prints the exact manual procedure to move the preserved previous data
# back into place. Only meaningful once a replacement has happened.
print_rollback() {
    cat <<EOF

  Roll back to the preserved data in $PREV - manual procedure:
    1) kubectl -n $NS scale statefulset $SET --replicas=0
    2) kubectl -n $NS run owui-rollback --restart=Never --image=$IMAGE \\
         --overrides='{ "spec": { "containers": [ { "name": "owui-rollback", "image": "$IMAGE", "command": ["sh", "-c", "set -e; p=$PREV; m=\$(mktemp -d /data/owui-prev-rollback-XXXXXX); for e in /data/* /data/.[!.]* /data/..?*; do [ -e \$e ] || [ -L \$e ] || continue; n=\${e##*/}; case \$n in owui-staging|owui-prev-*) continue;; esac; mv -f \$e \$m/; done; for e in \$p/* \$p/.[!.]* \$p/..?*; do [ -e \$e ] || [ -L \$e ] || continue; mv -f \$e /data/; done; rmdir \$p 2>/dev/null || true; echo done; sleep infinity"], "volumeMounts": [{ "name": "data", "mountPath": "/data" }] } ] } }, "volumes": [{ "name": "data", "persistentVolumeClaim": { "claimName": "$PVC" } }] }'
    3) kubectl -n $NS logs owui-rollback     # must print "done"
    4) kubectl -n $NS delete pod owui-rollback
    5) kubectl -n $NS scale statefulset $SET --replicas=$REPLICAS
  The restored data is preserved under /data/owui-prev-rollback-* (excluded
  from future backups); delete it once the app is confirmed healthy.
EOF
}

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

# --- extract into staging (live data untouched until the move) ----------
kubectl -n "$NS" exec "$HELPER" -- sh -c 'rm -rf "$1"' _ "$STAGING_IN_POD"
echo "Extracting archive into staging dir on $PVC..."
if ! kubectl -n "$NS" exec -i "$HELPER" -- sh -c 'mkdir -p "$1" && tar -xzf - -C "$1"' _ "$STAGING_IN_POD" < "$ARCHIVE"; then
    echo "Error: extraction into the staging dir failed (corrupt archive, or the PVC ran out of space)." >&2
    echo "The live data on $PVC is untouched. $SET will be scaled back to $REPLICAS replica(s) by the cleanup." >&2
    echo "Retry with a known-good archive: $0 $ARCHIVE $SET" >&2
    exit 1
fi

# --- validate the staged data before the live data is touched -----------
echo "Validating staged webui.db (PRAGMA quick_check with the image's Python)..."
if ! kubectl -n "$NS" exec "$HELPER" -- sh -c '
    set -e
    cd "$1"
    if [ ! -f webui.db ] || [ -L webui.db ]; then
        echo "Error: staged webui.db is missing or not a regular file" >&2
        exit 1
    fi
    py="$(command -v python3 || command -v python || true)"
    if [ -z "$py" ]; then
        echo "Error: no python3 in the helper image; cannot validate the database" >&2
        exit 1
    fi
    quick() {
        "$py" -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); ok=c.execute(\"PRAGMA quick_check\").fetchone()[0]==\"ok\"; c.close(); sys.exit(0 if ok else 1)" "$1"
    }
    if ! quick webui.db; then
        echo "Error: staged webui.db failed PRAGMA quick_check" >&2
        exit 1
    fi
    if [ "$2" = "yes" ]; then
        if [ ! -f vector_db/chroma.sqlite3 ]; then
            echo "Error: archive lists vector_db/chroma.sqlite3 but it is missing after extraction" >&2
            exit 1
        fi
        if ! quick vector_db/chroma.sqlite3; then
            echo "Error: staged vector_db/chroma.sqlite3 failed PRAGMA quick_check" >&2
            exit 1
        fi
    fi
' _ "$STAGING_IN_POD" "$has_chroma"; then
    echo "Error: the staged archive failed validation; the live data on $PVC is untouched." >&2
    echo "$SET will be scaled back to $REPLICAS replica(s) by the cleanup." >&2
    echo "Investigate the error above, then retry with a known-good archive:" >&2
    echo "  $0 $ARCHIVE $SET" >&2
    exit 1
fi

# --- replace the live data with the validated staged data ---------------
# From this point on, any failure leaves the app at 0 replicas.
echo "Replacing live data on $PVC (sequence of renames, not atomic)..."
phase="replacing"
if ! PREV="$(kubectl -n "$NS" exec "$HELPER" -- mktemp -d /data/owui-prev-XXXXXXXX)"; then
    echo "Error: could not allocate a previous-data dir on $PVC" >&2
    exit 1
fi
PRESERVED=0
if ! move_result="$(kubectl -n "$NS" exec "$HELPER" -- sh -c '
    set -e
    data="$1"; staging="$2"; prev="$3"
    if [ -n "$(find "$data" -mindepth 1 -maxdepth 1 ! -name owui-staging ! -name "owui-prev-*" -print -quit 2>/dev/null)" ]; then
        for entry in "$data"/* "$data"/.[!.]* "$data"/..?*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            name="${entry##*/}"
            case "$name" in
                owui-staging | owui-prev-*) continue ;;
            esac
            mv -f "$entry" "$prev/"
        done
        echo "status=preserved"
    else
        rmdir "$prev"
        echo "status=empty"
    fi
    for entry in "$staging"/* "$staging"/.[!.]* "$staging"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        mv -f "$entry" "$data/"
    done
    rmdir "$staging"
' _ "$DATA_DIR_IN_POD" "$STAGING_IN_POD" "$PREV")"; then
    echo "Error: replacing the data on $PVC failed partway through." >&2
    echo "The data may now be split between $DATA_MOUNT and $PREV. $SET is left at 0 replicas." >&2
    echo "Two options (the first owui-prev-* dir is the only copy of the original data):" >&2
    echo "  Retry the archive restore - preserves the current state in a NEW owui-prev-* dir" >&2
    echo "  and re-applies the archive (does not reconstruct the original dataset):" >&2
    echo "    $0 $ARCHIVE $SET" >&2
    print_rollback >&2
    exit 1
fi
case "$move_result" in
    *status=preserved*) PRESERVED=1 ;;
esac

# --- success: teardown, scale back up -----------------------------------
phase="done"
echo "Cleaning up..."
kubectl -n "$NS" delete pod "$HELPER" --grace-period=0
HELPER_CREATED=0
kubectl -n "$NS" wait --for=delete pod "$HELPER" --timeout=60s >/dev/null 2>&1 || true
if [ "$REPLICAS" -gt 0 ]; then
    kubectl -n "$NS" scale statefulset "$SET" --replicas="$REPLICAS"
    scaled_down=0
    if ! kubectl -n "$NS" wait --for=condition=Ready pod "$POD" --timeout=300s; then
        echo "Error: pod $POD not Ready within 300s after scale-up. The restore completed on $PVC, but the app is not up." >&2
        echo "Check: kubectl -n $NS logs $POD, kubectl -n $NS describe pod $POD" >&2
        exit 1
    fi
    echo "Restore complete: $SET is back at $REPLICAS replica(s)."
else
    echo "Restore complete. $SET was at 0 replicas at the start and is left at 0."
    echo "Scale it up with: kubectl -n $NS scale statefulset $SET --replicas=1"
fi
if [ "$PRESERVED" -eq 1 ]; then
    echo "Previous data is preserved on $PVC under $PREV (backups skip owui-prev-* dirs);" >&2
    echo "delete it once you have confirmed the restored app is healthy." >&2
fi
