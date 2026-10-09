#!/usr/bin/env bash
# Labs 2-3: what VPA recommends for each service, as ready-to-run commands.
# Usage:
#   ./tools/vpa-report.sh           show recommendations and the commands
#   ./tools/vpa-report.sh --apply   apply them (memory limit = request, CPU limit removed)

# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

readonly CPU_STEP_M=5     # round CPU up to the next 5m
readonly MEM_STEP_MI=16   # round memory up to the next 16Mi

round_up() { echo $(( ($1 + $2 - 1) / $2 * $2 )); }

# One line per VPA: name|target cpu|target memory|current cpu request|current memory request
vpa_targets() {
  local name cpu mem cur_cpu cur_mem
  for name in $(kubectl get vpa -n "${APP_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}'); do
    cpu=$(kubectl get vpa "${name}" -n "${APP_NAMESPACE}" \
      -o jsonpath='{.status.recommendation.containerRecommendations[0].target.cpu}')
    mem=$(kubectl get vpa "${name}" -n "${APP_NAMESPACE}" \
      -o jsonpath='{.status.recommendation.containerRecommendations[0].target.memory}')
    cur_cpu=$(kubectl get deploy "${name}" -n "${APP_NAMESPACE}" \
      -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')
    cur_mem=$(kubectl get deploy "${name}" -n "${APP_NAMESPACE}" \
      -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}')
    printf '%s|%s|%s|%s|%s\n' "${name}" "${cpu}" "${mem}" "${cur_cpu:-none}" "${cur_mem:-none}"
  done
}

# Prints "name cpu_m mem_mi" per service that has a recommendation; table goes to stderr.
recommendations() {
  local name cpu mem cur_cpu cur_mem cpu_m mem_mi missing=0
  printf '%-10s %-18s %-18s\n' "SERVICE" "REQUEST NOW" "VPA RECOMMENDS" >&2
  while IFS='|' read -r name cpu mem cur_cpu cur_mem; do
    if [[ -z "${cpu}" || -z "${mem}" ]]; then
      printf '%-10s %-18s %-18s\n' "${name}" "${cur_cpu} / ${cur_mem}" "(no data yet)" >&2
      missing=$((missing + 1))
      continue
    fi
    cpu_m=$(round_up "$(cpu_to_m "${cpu}")" "${CPU_STEP_M}")
    mem_mi=$(round_up "$(mem_to_mi "${mem}")" "${MEM_STEP_MI}")
    printf '%-10s %-18s %-18s\n' "${name}" "${cur_cpu} / ${cur_mem}" "${cpu_m}m / ${mem_mi}Mi" >&2
    echo "${name} ${cpu_m} ${mem_mi}"
  done < <(vpa_targets)
  (( missing == 0 )) || warn "VPA needs a few minutes of load before it recommends. Try again shortly."
}

main() {
  use_workshop_context
  local recs name cpu_m mem_mi
  recs=$(recommendations)
  [[ -n "${recs}" ]] || return 0

  if [[ "${1:-}" != "--apply" ]]; then
    printf '\nTo apply these (memory limit = request; cpu=0 removes the CPU limit), run:\n\n' >&2
    while read -r name cpu_m mem_mi; do
      printf 'kubectl set resources deploy/%s -n %s --requests=cpu=%sm,memory=%sMi --limits=cpu=0,memory=%sMi\n' \
        "${name}" "${APP_NAMESPACE}" "${cpu_m}" "${mem_mi}" "${mem_mi}"
    done <<< "${recs}"
    printf '\nor simply: ./tools/vpa-report.sh --apply\n' >&2
    return 0
  fi

  log "Applying recommendations"
  while read -r name cpu_m mem_mi; do
    kubectl set resources "deploy/${name}" -n "${APP_NAMESPACE}" \
      --requests="cpu=${cpu_m}m,memory=${mem_mi}Mi" --limits="cpu=0,memory=${mem_mi}Mi"
  done <<< "${recs}"
}

main "$@"
