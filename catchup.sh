#!/usr/bin/env bash
# Resets your cluster to the start of any lab, so nobody gets left behind.
# VPA history is kept, so recommendations stay available.
#
# Usage: ./catchup.sh <lab number 1-5>
#   1-3  bloated shop on all 4 app nodes
#   4-5  right-sized shop on 2 app nodes (worker4 and worker5 cordoned)

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

readonly POD_TIMEOUT_S=240
expected_pods=0

usage() { die "Usage: ./catchup.sh <lab number 1-5>"; }

remove_lab_changes() {
  log "Clearing changes from later labs"
  kubectl delete pdb,limitrange,resourcequota --all -n "${APP_NAMESPACE}" --ignore-not-found >/dev/null
  kubectl delete priorityclass shop-critical shop-standard shop-batch --ignore-not-found >/dev/null
  kubectl delete pods -n "${APP_NAMESPACE}" -l '!app' --ignore-not-found >/dev/null
  # Deleting the deployments also drops anything set imperatively (kubectl set resources).
  kubectl delete deployments --all -n "${APP_NAMESPACE}" --wait=true >/dev/null
  # Old pods keep their requests until they are gone, so wait for them.
  kubectl wait --for=delete pod --all -n "${APP_NAMESPACE}" --timeout=180s >/dev/null 2>&1 || true
}

set_app_nodes() {
  local should_cordon="$1" node
  for node in ${APP_NODES}; do
    kubectl uncordon "${node}" >/dev/null
  done
  [[ "${should_cordon}" == "true" ]] || return 0
  for node in ${NODES_TO_DRAIN}; do
    kubectl cordon "${node}" >/dev/null
  done
}

enough_pods_running() {
  (( $(running_pods "") >= expected_pods ))
}

deploy_stage() {
  local overlay="$1"
  kubectl apply -k "${REPO_ROOT}/app/${overlay}" >/dev/null
  wait_for "${POD_TIMEOUT_S}" enough_pods_running \
    || die "Pods didn't start in time. Check: kubectl get pods -n ${APP_NAMESPACE}"
}

main() {
  local lab="${1:-}"
  [[ "${lab}" =~ ^[1-5]$ ]] || usage

  if ! cluster_exists; then
    warn "No cluster found, running setup first"
    "${REPO_ROOT}/setup.sh"
  fi
  use_workshop_context
  remove_lab_changes

  if (( lab <= 3 )); then
    set_app_nodes false
    expected_pods=8   # the 9th bloated pod has nowhere to go
    deploy_stage bloated
  else
    set_app_nodes true
    expected_pods=9
    deploy_stage rightsized
  fi
  ok "Ready for Lab ${lab}. Pick up the tutorial at the start of that lab."
}

main "$@"
