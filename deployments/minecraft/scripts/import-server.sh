#!/bin/sh
set -eu

usage() {
  echo "Usage: $0 [--replace] <existing-server-directory> [namespace]" >&2
  echo "Example: $0 /path/to/minecraft-server minecraft" >&2
  echo "         $0 --replace /path/to/minecraft-server minecraft" >&2
  exit 2
}

replace_existing=false
if [ "${1:-}" = "--replace" ]; then
  replace_existing=true
  shift
fi

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage

source_dir=$1
namespace=${2:-minecraft}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
import_pod=data-import
statefulset=minecraft-server

[ -d "$source_dir" ] || { echo "Not a directory: $source_dir" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }

# Require a stopped server before attaching the import pod to its ReadWriteOnce PVC.
replicas=$(kubectl -n "$namespace" get statefulset "$statefulset" -o jsonpath='{.spec.replicas}')

cleanup() {
  trap - EXIT HUP INT TERM
  echo "Cleanup: requesting deletion of importer pod/$import_pod..." >&2
  if ! kubectl -n "$namespace" delete pod "$import_pod" --ignore-not-found --wait=false; then
    echo "Cleanup warning: could not delete pod/$import_pod. Delete it manually if it remains." >&2
  fi
  if [ "$replicas" != "0" ]; then
    echo "Cleanup: restoring StatefulSet/$statefulset to $replicas replica(s)..." >&2
    if ! kubectl -n "$namespace" scale statefulset "$statefulset" --replicas="$replicas"; then
      echo "Cleanup warning: could not restore the StatefulSet. Scale it manually with: kubectl -n $namespace scale statefulset/$statefulset --replicas=$replicas" >&2
    fi
  else
    echo "Cleanup: StatefulSet was already scaled to zero; leaving it stopped." >&2
  fi
}

on_signal() {
  signal_status=$1
  echo "Interrupted; requesting cleanup and exiting (status $signal_status)." >&2
  exit "$signal_status"
}

trap cleanup EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

if [ "$replicas" != "0" ]; then
  kubectl -n "$namespace" scale statefulset "$statefulset" --replicas=0
fi

echo "Starting importer pod..."
kubectl -n "$namespace" apply -f "$script_dir/../base/data-import.yaml"
kubectl -n "$namespace" wait --for=condition=Ready "pod/$import_pod" --timeout=180s
echo "Importer pod is ready."

# Do not mix an import with data already present on the PVC. Ignore lost+found,
# which may be created automatically by the filesystem.
existing=$(kubectl -n "$namespace" exec "$import_pod" -- sh -c 'find /data -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit')
if [ -n "$existing" ]; then
  if [ "$replace_existing" != "true" ]; then
    echo "Import aborted: /data is not empty (found $existing). Back up the PVC, then rerun with --replace to remove its contents." >&2
    exit 1
  fi

  if [ ! -t 0 ]; then
    echo "Import aborted: --replace requires an interactive terminal for confirmation." >&2
    exit 1
  fi

  printf 'WARNING: this will permanently delete all existing files in PVC /data before importing. Type DELETE to continue: ' >&2
  IFS= read -r confirmation
  if [ "$confirmation" != "DELETE" ]; then
    echo "Import cancelled; existing PVC data was not changed." >&2
    exit 1
  fi

  kubectl -n "$namespace" exec "$import_pod" -- sh -c 'find /data -mindepth 1 ! -name lost+found -exec rm -rf -- {} +'
fi

# Archive directory contents (not the enclosing directory), preserving hidden files.
# tar's verbose output provides file-by-file activity without requiring pv.
echo "Transferring server files (tar will list each file as it is archived)..."
tar -C "$source_dir" -cvf - . | kubectl -n "$namespace" exec -i "$import_pod" -- tar -C /data -xf -

echo "Transfer complete. The Minecraft StatefulSet will be started again by cleanup."
