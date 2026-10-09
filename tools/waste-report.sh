#!/usr/bin/env bash
# Lab 1: requests vs real usage for every shop service, side by side.
# Usage: ./tools/waste-report.sh

# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

# One line per pod: name|app|phase|cpu request|memory request
pod_requests() {
  kubectl get pods -n "${APP_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.app}{"|"}{.status.phase}{"|"}{.spec.containers[0].resources.requests.cpu}{"|"}{.spec.containers[0].resources.requests.memory}{"\n"}{end}'
}

# Normalised line per pod: app|phase|cpu req m|mem req Mi|cpu used m|mem used Mi
normalise() {
  local usage="$1" name app phase req_cpu req_mem used_cpu used_mem
  while IFS='|' read -r name app phase req_cpu req_mem; do
    [[ -z "${name}" ]] && continue
    used_cpu=$(awk -v p="${name}" '$1 == p {print $2}' <<< "${usage}")
    used_mem=$(awk -v p="${name}" '$1 == p {print $3}' <<< "${usage}")
    printf '%s|%s|%s|%s|%s|%s\n' "${app}" "${phase}" \
      "$(cpu_to_m "${req_cpu}")" "$(mem_to_mi "${req_mem}")" \
      "$(cpu_to_m "${used_cpu}")" "$(mem_to_mi "${used_mem}")"
  done
}

print_table() {
  awk -f "${REPO_ROOT}/lib/waste-table.awk"
}

main() {
  use_workshop_context
  local usage
  usage=$(kubectl top pods -n "${APP_NAMESPACE}" --no-headers 2>/dev/null) \
    || die "No metrics yet. metrics-server needs about a minute after setup; try again shortly."
  pod_requests | normalise "${usage}" | sort | print_table
}

main "$@"
