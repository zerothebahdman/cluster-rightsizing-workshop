#!/usr/bin/env bash
# Deletes the workshop cluster. Run ./setup.sh to start again from scratch.
# Usage: ./cleanup.sh

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

require_cmd kind
if cluster_exists; then
  kind delete cluster --name "${CLUSTER_NAME}"
  ok "Cluster '${CLUSTER_NAME}' deleted"
else
  ok "No cluster to delete"
fi
