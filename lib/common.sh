#!/usr/bin/env bash
# Shared settings and helpers for every workshop script. Source it; don't run it.
# Kept bash 3.2 compatible so the unit tests also run on macOS.
# shellcheck disable=SC2034  # constants are used by the scripts that source this file

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT

readonly CLUSTER_NAME="workshop"
readonly KUBE_CONTEXT="kind-${CLUSTER_NAME}"
# kindest/node:v1.37.0, copied to ghcr.io by .github/workflows/mirror-node-image.yml.
# Cloud Shell pulls it from ghcr.io in ~20s vs 4-11 min via Docker Hub's mirror
# (tests/registry-check.sh, 2026-10-10). Same digest, so it is the identical image.
readonly NODE_IMAGE="ghcr.io/zerothebahdman/kind-node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5"
readonly METRICS_SERVER_VERSION="v0.7.2"
readonly VPA_TAG="vertical-pod-autoscaler-1.3.0"

readonly APP_NAMESPACE="shop"
readonly LOAD_NAMESPACE="load"
readonly PLATFORM_NODE="${CLUSTER_NAME}-worker"
readonly APP_NODES="${CLUSTER_NAME}-worker2 ${CLUSTER_NAME}-worker3 ${CLUSTER_NAME}-worker4 ${CLUSTER_NAME}-worker5"
readonly NODES_TO_DRAIN="${CLUSTER_NAME}-worker4 ${CLUSTER_NAME}-worker5"

# Every node advertises this much allocatable, whatever the VM size.
readonly NODE_CPU_M=1000
readonly NODE_MEM_MI=1024

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m ✗ %s\033[0m\n' "$*" >&2; exit 1; }

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || die "'${cmd}' not found. Are you in Google Cloud Shell?"
  done
}

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"
}

use_workshop_context() {
  cluster_exists || die "Cluster '${CLUSTER_NAME}' not found. Run ./setup.sh first."
  kubectl config use-context "${KUBE_CONTEXT}" >/dev/null
}

# CPU quantity -> integer millicores. "400m"->400, "1"->1000, "0.5"->500, "1500000n"->2
cpu_to_m() {
  awk -v q="${1:-0}" 'BEGIN {
    if (q == "" || q == "<none>") { print 0; exit }
    n = q + 0; u = substr(q, length(q))
    if (u == "m") v = n
    else if (u == "u") v = n / 1000
    else if (u == "n") v = n / 1000000
    else v = n * 1000
    printf "%d\n", (v == int(v)) ? v : int(v) + 1
  }'
}

# Memory quantity -> integer MiB, rounded up. "256Mi"->256, "1Gi"->1024, "262144k"->250
mem_to_mi() {
  awk -v q="${1:-0}" 'BEGIN {
    if (q == "" || q == "<none>") { print 0; exit }
    n = q + 0
    s = q; sub(/^[0-9.]+/, "", s)
    f["Ki"] = 1024; f["Mi"] = 1048576; f["Gi"] = 1073741824; f["Ti"] = 1099511627776
    f["k"] = 1000; f["M"] = 1000000; f["G"] = 1000000000; f["T"] = 1000000000000; f[""] = 1
    if (!(s in f)) { print "ERR"; exit 1 }
    v = n * f[s] / 1048576
    printf "%d\n", (v == int(v)) ? v : int(v) + 1
  }'
}

# Running shop pods that are not shutting down.
# Usage: running_pods [extra field selector] [kubectl args...]   e.g. running_pods "" -l app=worker
running_pods() {
  local extra="${1:-}"
  [[ $# -gt 0 ]] && shift
  kubectl get pods -n "${APP_NAMESPACE}" --field-selector="status.phase=Running${extra:+,${extra}}" "$@" \
    -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"\n"}{end}' 2>/dev/null | grep -c '^$' || true
}

# Polls a command until it succeeds or the timeout (seconds) passes.
wait_for() {
  local timeout_s="$1"; shift
  local deadline=$(( $(date +%s) + timeout_s ))
  until "$@" >/dev/null 2>&1; do
    (( $(date +%s) < deadline )) || return 1
    sleep 3
  done
}
