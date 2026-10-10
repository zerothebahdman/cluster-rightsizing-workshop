#!/usr/bin/env bash
# Measures how fast Cloud Shell can pull the workshop's Docker Hub images, directly
# and through Google's mirror (mirror.gcr.io), and shows the Docker Hub rate limit.
# Run it in a freshly restarted Cloud Shell, with no workshop cluster running.
#
# Run: ./tests/registry-check.sh

# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

readonly PULL_TIMEOUT_S=900
readonly NODE_DIGEST="${NODE_IMAGE#*@}"
readonly CURL_IMAGE="curlimages/curl:8.11.1"

docker_hub_rate_limit() {
  local token
  token=$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull" \
    | sed -E 's/.*"token":"([^"]+)".*/\1/') || { echo "could not reach Docker Hub"; return; }
  curl -fsSI -H "Authorization: Bearer ${token}" \
    https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest \
    | grep -iE '^(ratelimit-limit|ratelimit-remaining|docker-ratelimit-source)' || echo "no rate-limit headers returned"
}

# Pulls an image from scratch and prints how long it took.
timed_pull() {
  local label="$1" image="$2" start status=0
  docker rmi -f "${image}" >/dev/null 2>&1 || true
  start=$(date +%s)
  timeout "${PULL_TIMEOUT_S}" docker pull -q "${image}" >/dev/null 2>&1 || status=$?
  if (( status == 0 )); then
    printf '%-34s %5ss\n' "${label}" "$(( $(date +%s) - start ))"
  else
    printf '%-34s FAILED or timed out after %ss (exit %s)\n' "${label}" "$(( $(date +%s) - start ))" "${status}"
  fi
  docker rmi -f "${image}" >/dev/null 2>&1 || true
}

main() {
  require_cmd docker curl timeout
  cluster_exists && die "Delete the workshop cluster first (./cleanup.sh) so the node image can be removed."

  log "Docker daemon registry mirrors"
  docker info --format '{{range .RegistryConfig.Mirrors}}{{.}} {{end}}' | sed 's/^$/(none)/'

  log "Docker Hub anonymous rate limit for this Cloud Shell"
  docker_hub_rate_limit

  log "Pull times (each image removed first)"
  timed_pull "node image via ghcr.io" "ghcr.io/zerothebahdman/kind-node@${NODE_DIGEST}"
  timed_pull "node image via Docker Hub (mirror)" "docker.io/kindest/node@${NODE_DIGEST}"
  timed_pull "curl image via mirror.gcr.io" "mirror.gcr.io/${CURL_IMAGE}"
  timed_pull "curl image via Docker Hub" "docker.io/${CURL_IMAGE}"

  log "Docker Hub rate limit afterwards"
  docker_hub_rate_limit
}

main "$@"
