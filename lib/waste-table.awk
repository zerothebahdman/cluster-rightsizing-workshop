# Aggregates per-pod lines into a per-service waste table.
# Input (one line per pod, "|"-separated):
#   app|phase|cpu request m|memory request Mi|cpu used m|memory used Mi
# Used by tools/waste-report.sh and tested in tests/unit.sh.

BEGIN { FS = "|" }

function waste(req, used) {
  if (req <= 0) return "-"
  return sprintf("%d%%", used > req ? 0 : 100 - used * 100 / req)
}

NF >= 6 {
  if (!($1 in pods)) order[++n] = $1
  pods[$1]++
  if ($2 == "Pending") { pending[$1]++; pending_total++ }
  rc[$1] += $3; rm[$1] += $4; uc[$1] += $5; um[$1] += $6
}

END {
  fmt = "%-10s %-6s %9s %9s %7s %9s %9s %7s\n"
  printf fmt, "SERVICE", "PODS", "CPU REQ", "CPU USED", "WASTE", "MEM REQ", "MEM USED", "WASTE"
  for (i = 1; i <= n; i++) {
    a = order[i]
    p = pods[a] ((a in pending) ? "*" : "")   # "in" test: reading pending[a] would create it
    printf fmt, a, p, rc[a] "m", uc[a] "m", waste(rc[a], uc[a]), rm[a] "Mi", um[a] "Mi", waste(rm[a], um[a])
    trc += rc[a]; tuc += uc[a]; trm += rm[a]; tum += um[a]
  }
  printf fmt, "TOTAL", "", trc "m", tuc "m", waste(trc, tuc), trm "Mi", tum "Mi", waste(trm, tum)
  if (pending_total > 0) print "\n* includes a Pending pod: it has a request but no node to run on."
}
