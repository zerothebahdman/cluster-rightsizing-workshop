#!/usr/bin/env bash
# End-to-end rehearsal of the whole workshop, run inside Cloud Shell (~20 minutes).
# Starts from a fresh cluster, walks every lab like an attendee, and checks each outcome.
# Writes ~/e2e-report.txt; the cluster is left running for inspection.
#
# Run: ./tests/e2e.sh

# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

readonly REPORT="${HOME}/e2e-report.txt"
readonly SETUP_BUDGET_S=360
readonly LOAD_WARMUP_S=150
readonly STABILITY_WINDOW_S=180
readonly VPA_TIMEOUT_S=420
readonly MIN_SHOP_CPU_M=300
readonly THROTTLE_CEILING_M=70

passed=0
failed=0

record() { printf '%s\n' "$*" | tee -a "${REPORT}"; }
check() {
  local description="$1"; shift
  if "$@"; then passed=$((passed + 1)); record "PASS: ${description}"
  else failed=$((failed + 1)); record "FAIL: ${description}"; fi
}
section() { record ""; record "=== $* ==="; }
capture() { "$@" 2>&1 | tee -a "${REPORT}" || true; }

shop() { kubectl -n "${APP_NAMESPACE}" "$@"; }
count_pods() { shop get pods --no-headers "$@" 2>/dev/null | wc -l | tr -d ' '; }

# --- assertions ---------------------------------------------------------------
setup_within_budget() { (( $1 <= SETUP_BUDGET_S )); }
bloated_counts_ok() { [[ "$(running_pods "")" == 8 && "$(count_pods --field-selector=status.phase=Pending)" == 1 ]]; }
two_per_app_node() {
  local node
  for node in ${APP_NODES}; do
    [[ "$(running_pods "spec.nodeName=${node}")" == 2 ]] || return 1
  done
}
shop_cpu_m() { shop top pods --no-headers | awk '{sum += $2} END {print sum + 0}'; }
load_is_running() { (( $(shop_cpu_m) >= MIN_SHOP_CPU_M )); }
all_vpas_ready() {
  local targets
  targets=$(shop get vpa -o jsonpath='{range .items[*]}{.status.recommendation.containerRecommendations[0].target.cpu}{"\n"}{end}' | grep -c .)
  [[ "${targets}" == 5 ]]
}
nothing_on_drained_nodes() {
  local node
  for node in ${NODES_TO_DRAIN}; do
    [[ "$(count_pods --field-selector="spec.nodeName=${node}")" == 0 ]] || return 1
  done
}
all_nine_running() { [[ "$(running_pods "")" == 9 ]]; }
total_restarts() { shop get pods -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | awk '{s += $1} END {print s + 0}'; }
no_restarts() { [[ "$(total_restarts)" == 0 ]]; }
cart_oomkilled() {
  shop get pods -l app=cart -o jsonpath='{.items[*].status.containerStatuses[0].lastState.terminated.reason}' | grep -q OOMKilled
}
worker_throttled() {
  shop top pods -l app=worker --no-headers | awk -v max="${THROTTLE_CEILING_M}" '{ if ($2 + 0 > max) bad = 1 } END { exit bad }'
}
worker_preempted() { (( $(running_pods "" -l app=worker) < 2 )); }
naked_pod_defaulted() { [[ "$(shop get pod naked -o jsonpath='{.spec.containers[0].resources.requests.cpu}')" == "50m" ]]; }
quota_blocked() { shop get events --field-selector=reason=FailedCreate -o jsonpath='{.items[*].message}' | grep -q "exceeded quota"; }

# --- lab walkthrough ------------------------------------------------------------
step_setup() {
  section "Setup (fresh cluster)"
  "${REPO_ROOT}/cleanup.sh"
  local start elapsed; start=$(date +%s)
  "${REPO_ROOT}/setup.sh"
  elapsed=$(( $(date +%s) - start ))
  record "setup_seconds: ${elapsed}"
  check "setup finished within ${SETUP_BUDGET_S}s" setup_within_budget "${elapsed}"
  check "bloated: 8 Running and 1 Pending" bloated_counts_ok
  check "bloated: exactly 2 shop pods on every app node" two_per_app_node
}

step_measure() {
  section "Lab 1: measure (after ${LOAD_WARMUP_S}s of load)"
  sleep "${LOAD_WARMUP_S}"
  capture "${REPO_ROOT}/tools/waste-report.sh"
  record "shop_cpu_used_m: $(shop_cpu_m)"
  check "load generator drives at least ${MIN_SHOP_CPU_M}m of CPU" load_is_running
  capture kubectl -n "${LOAD_NAMESPACE}" logs deploy/loadgen --tail=3
}

step_recommend() {
  section "Lab 2: recommend"
  check "all 5 VPAs have a recommendation" wait_for "${VPA_TIMEOUT_S}" all_vpas_ready
  capture "${REPO_ROOT}/tools/vpa-report.sh"
}

step_rightsize() {
  section "Lab 3: right-size and drain"
  kubectl apply -k "${REPO_ROOT}/app/rightsized" >/dev/null
  local node
  for node in ${NODES_TO_DRAIN}; do
    kubectl drain "${node}" --ignore-daemonsets --delete-emptydir-data --timeout=180s >/dev/null 2>&1 || true
  done
  check "all 9 pods running after the drain" wait_for 240 all_nine_running
  check "nothing left on the drained nodes" nothing_on_drained_nodes
  capture "${REPO_ROOT}/tools/nodes.sh"
  sleep "${STABILITY_WINDOW_S}"
  check "reference sizes survive ${STABILITY_WINDOW_S}s of load with no restarts" no_restarts
  capture "${REPO_ROOT}/tools/waste-report.sh"
}

step_break_it() {
  section "Lab 4: break it"
  shop set resources deploy/cart --requests=memory=24Mi --limits=memory=24Mi >/dev/null
  check "cart gets OOMKilled with a 24Mi limit" wait_for 240 cart_oomkilled
  shop set resources deploy/worker --requests=cpu=40m --limits=cpu=50m >/dev/null
  sleep 150
  check "worker CPU is throttled to about 50m" worker_throttled
  capture shop top pods -l app=worker
  record "cpu.stat from inside a throttled worker (optional for the lab):"
  capture shop exec deploy/worker -- cat /sys/fs/cgroup/cpu.stat
}

step_rails() {
  section "Lab 5: safety rails"
  "${REPO_ROOT}/catchup.sh" 5
  kubectl apply -f "${REPO_ROOT}/rails-demo/strict-pdb.yaml" >/dev/null
  local node drain_output
  node=$(shop get pod -l app=checkout -o jsonpath='{.items[0].spec.nodeName}')
  drain_output=$(kubectl drain "${node}" --ignore-daemonsets --delete-emptydir-data --dry-run=server --timeout=20s 2>&1 || true)
  record "${drain_output}"
  check "strict PDB blocks a server-side dry-run drain" grep -q "disruption budget" <<< "${drain_output}"
  kubectl delete -f "${REPO_ROOT}/rails-demo/strict-pdb.yaml" >/dev/null

  kubectl apply -k "${REPO_ROOT}/rails" >/dev/null
  check "all 9 pods running with rails applied" wait_for 240 all_nine_running
  shop scale deploy/checkout --replicas=12 >/dev/null
  check "high-priority checkout pods preempt the batch worker" wait_for 120 worker_preempted
  shop scale deploy/checkout --replicas=2 >/dev/null

  shop run naked --image=registry.k8s.io/e2e-test-images/resource-consumer:1.13 --restart=Never >/dev/null
  check "LimitRange gives a naked pod default requests" naked_pod_defaulted
  shop delete pod naked --wait=false >/dev/null

  shop delete events --all >/dev/null
  shop scale deploy/gateway --replicas=30 >/dev/null
  check "ResourceQuota blocks scaling gateway to 30" wait_for 60 quota_blocked
  shop scale deploy/gateway --replicas=2 >/dev/null
}

main() {
  : > "${REPORT}"
  record "e2e started: $(date -u +%FT%TZ)"
  step_setup
  step_measure
  step_recommend
  step_rightsize
  step_break_it
  step_rails
  section "Result"
  record "${passed} passed, ${failed} failed"
  printf '\nFull report: %s\n' "${REPORT}"
  (( failed == 0 ))
}

main "$@"
