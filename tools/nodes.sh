#!/usr/bin/env bash
# How full is each node, as the scheduler sees it (requests, not usage)?
# Usage: ./tools/nodes.sh

# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

readonly BAR_WIDTH=20

# One line per node: name|role|cordoned|alloc cpu m|alloc mem Mi
node_capacity() {
  local name role cordoned cpu mem
  kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.node-role}{"|"}{.spec.unschedulable}{"|"}{.status.allocatable.cpu}{"|"}{.status.allocatable.memory}{"\n"}{end}' \
    | while IFS='|' read -r name role cordoned cpu mem; do
        printf '%s|%s|%s|%s|%s\n' "${name}" "${role:-?}" "${cordoned:-false}" "$(cpu_to_m "${cpu}")" "$(mem_to_mi "${mem}")"
      done
}

# One line per scheduled container: node|cpu req m|mem req Mi
container_requests() {
  local node containers entry cpu mem
  local -a entries
  kubectl get pods -A --field-selector=status.phase!=Succeeded,status.phase!=Failed -o jsonpath='{range .items[*]}{.spec.nodeName}{"|"}{range .spec.containers[*]}{.resources.requests.cpu}{","}{.resources.requests.memory}{";"}{end}{"\n"}{end}' \
    | while IFS='|' read -r node containers; do
        [[ -z "${node}" ]] && continue   # Pending pods have no node yet
        IFS=';' read -ra entries <<< "${containers}"
        for entry in "${entries[@]}"; do
          cpu="${entry%%,*}"; mem="${entry#*,}"
          printf '%s|%s|%s\n' "${node}" "$(cpu_to_m "${cpu}")" "$(mem_to_mi "${mem}")"
        done
      done
}

main() {
  use_workshop_context
  local requests
  requests=$(container_requests)
  node_capacity | awk -F'|' -v reqs="${requests}" -v width="${BAR_WIDTH}" '
    function bar(used, total,   filled, s, i) {
      filled = total > 0 ? int(used * width / total + 0.5) : 0
      if (filled > width) filled = width
      s = ""; for (i = 0; i < width; i++) s = s (i < filled ? "#" : ".")
      return s
    }
    BEGIN {
      n = split(reqs, lines, "\n")
      for (i = 1; i <= n; i++) { split(lines[i], f, "|"); cpu[f[1]] += f[2]; mem[f[1]] += f[3] }
      printf "%-18s %-9s %-10s %-34s %s\n", "NODE", "ROLE", "STATUS", "CPU REQUESTED", "MEMORY REQUESTED"
    }
    {
      status = ($3 == "true") ? "cordoned" : "ready"
      printf "%-18s %-9s %-10s [%s] %4dm/%dm   [%s] %4dMi/%dMi\n", $1, $2, status,
        bar(cpu[$1], $4), cpu[$1], $4, bar(mem[$1], $5), mem[$1], $5
    }'
}

main "$@"
