#!/usr/bin/env bash
# Lints every shell script and checks that all kustomizations build.
# Run: ./tests/lint.sh   (needs shellcheck and kubectl)

set -euo pipefail
cd "$(dirname "$0")/.."

# -P SCRIPTDIR resolves each `source` relative to the script that sources it.
shellcheck -x -P SCRIPTDIR ./*.sh lib/*.sh tools/*.sh tests/*.sh
echo "shellcheck: clean"

for overlay in app/bloated app/rightsized rails; do
  kubectl kustomize "${overlay}" >/dev/null
  echo "kustomize ${overlay}: builds"
done
