#!/usr/bin/env bash
# Unit tests for the quantity helpers in lib/common.sh. No cluster needed.
# Run: ./tests/unit.sh

# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

failures=0
passes=0

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    passes=$((passes + 1))
  else
    failures=$((failures + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "${description}" "${expected}" "${actual}"
  fi
}

test_cpu_to_m() {
  assert_eq "millicores pass through" "400" "$(cpu_to_m 400m)"
  assert_eq "whole cores convert" "1000" "$(cpu_to_m 1)"
  assert_eq "fractional cores convert" "500" "$(cpu_to_m 0.5)"
  assert_eq "nanocores round up" "2" "$(cpu_to_m 1500000n)"
  assert_eq "microcores convert" "25" "$(cpu_to_m 25000u)"
  assert_eq "missing value is zero" "0" "$(cpu_to_m '<none>')"
  assert_eq "empty value is zero" "0" "$(cpu_to_m '')"
}

test_mem_to_mi() {
  assert_eq "Mi passes through" "256" "$(mem_to_mi 256Mi)"
  assert_eq "Gi converts" "1024" "$(mem_to_mi 1Gi)"
  assert_eq "Ki converts and rounds up" "1125" "$(mem_to_mi 1151856Ki)"
  assert_eq "decimal k (VPA output) converts" "250" "$(mem_to_mi 262144k)"
  assert_eq "plain bytes convert" "64" "$(mem_to_mi 67108864)"
  assert_eq "decimal M rounds up" "96" "$(mem_to_mi 100M)"
  assert_eq "missing value is zero" "0" "$(mem_to_mi '<none>')"
}

waste_table() { awk -f "${REPO_ROOT}/lib/waste-table.awk"; }

row_for() { grep "^$1 " | tr -s ' '; }

test_waste_table() {
  local table
  table=$(printf '%s\n' \
    "gateway|Running|400|256|40|50" \
    "gateway|Running|400|256|44|54" \
    "worker|Running|400|256|150|90" \
    "worker|Pending|400|256|0|0" \
    "cart|Running|100|64|150|70" \
    "naked|Running|0|0|20|30" | waste_table)
  assert_eq "sums pods per service" "gateway 2 800m 84m 89% 512Mi 104Mi 79%" "$(row_for gateway <<< "${table}")"
  assert_eq "marks services with a Pending pod" "worker 2* 800m 150m 81% 512Mi 90Mi 82%" "$(row_for worker <<< "${table}")"
  assert_eq "usage above request clamps to 0%" "cart 1 100m 150m 0% 64Mi 70Mi 0%" "$(row_for cart <<< "${table}")"
  assert_eq "no request prints a dash" "naked 1 0m 20m - 0Mi 30Mi -" "$(row_for naked <<< "${table}")"
  assert_eq "totals every service" "TOTAL 1700m 404m 76% 1088Mi 294Mi 72%" "$(row_for TOTAL <<< "${table}")"
  assert_eq "explains the Pending marker" "1" "$(grep -c 'Pending pod' <<< "${table}")"
}

test_cpu_to_m
test_mem_to_mi
test_waste_table

printf '%d passed, %d failed\n' "${passes}" "${failures}"
(( failures == 0 ))
