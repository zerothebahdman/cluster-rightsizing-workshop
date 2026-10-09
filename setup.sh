#!/usr/bin/env bash
# Builds the workshop cluster inside Cloud Shell and deploys the bloated shop.
# Safe to re-run: every step checks or overwrites instead of failing.
#
#   control-plane   Kubernetes itself
#   workshop-worker the "platform" node: DNS, metrics-server, VPA, load generator
#   worker2..5      four small app nodes, each capped at 1 CPU / 1 GiB
#
# Usage: ./setup.sh

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

readonly APP_READY_TIMEOUT_S=300
readonly EXPECTED_RUNNING_PODS=8   # 9 bloated pods, only 8 fit

KIND_CONFIG="$(mktemp)"
readonly KIND_CONFIG
trap 'rm -f "${KIND_CONFIG}"' EXIT

preflight() {
  require_cmd docker kind kubectl
  docker info >/dev/null 2>&1 || die "Docker isn't running. Restart Cloud Shell and try again."
  [[ "${CLOUD_SHELL:-false}" == "true" ]] || warn "Not in Cloud Shell. This workshop is only tested there."
}

# Reserve everything except NODE_CPU_M / NODE_MEM_MI, so every node advertises a small
# allocatable even though each kind node can see the whole VM.
write_kind_config() {
  local total_mem_mi reserve_cpu_m reserve_mem_mi
  total_mem_mi=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
  reserve_cpu_m=$(( $(nproc) * 1000 - NODE_CPU_M ))
  # kind sets its own evictionHard (disk only), so no memory eviction threshold is subtracted.
  reserve_mem_mi=$(( total_mem_mi - NODE_MEM_MI ))
  (( reserve_cpu_m >= 0 && reserve_mem_mi >= 0 )) || die "This machine is too small for the workshop cluster."
  cat > "${KIND_CONFIG}" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
kubeadmConfigPatches:
- |
  kind: KubeletConfiguration
  systemReserved:
    cpu: "${reserve_cpu_m}m"
    memory: "${reserve_mem_mi}Mi"
nodes:
- role: control-plane
- role: worker
- role: worker
- role: worker
- role: worker
- role: worker
EOF
}

create_cluster() {
  if cluster_exists; then
    ok "Cluster '${CLUSTER_NAME}' already exists, reusing it"
    use_workshop_context
    return
  fi
  log "Creating the cluster (about 3 minutes the first time)"
  write_kind_config
  kind create cluster --name "${CLUSTER_NAME}" --image "${NODE_IMAGE}" \
    --config "${KIND_CONFIG}" --wait 5m || die "Cluster creation failed. Run ./cleanup.sh, then ./setup.sh again."
  ok "Cluster created"
}

label_nodes() {
  local node
  kubectl label node "${PLATFORM_NODE}" node-role=platform --overwrite >/dev/null
  kubectl taint node "${PLATFORM_NODE}" dedicated=platform:NoSchedule --overwrite >/dev/null
  for node in ${APP_NODES}; do
    kubectl label node "${node}" node-role=app --overwrite >/dev/null
  done
  ok "Platform node and app nodes labelled"
}

# Moves a system deployment onto the platform node.
pin_to_platform() {
  local ns="$1" deploy="$2"
  kubectl -n "${ns}" patch deployment "${deploy}" --type=strategic -p '{
    "spec":{"template":{"spec":{
      "nodeSelector":{"node-role":"platform"},
      "tolerations":[{"key":"dedicated","value":"platform","effect":"NoSchedule"}]
    }}}}' >/dev/null
}

move_system_pods() {
  kubectl -n kube-system scale deployment coredns --replicas=1 >/dev/null
  pin_to_platform kube-system coredns
  pin_to_platform local-path-storage local-path-provisioner
  kubectl -n kube-system rollout status deployment coredns --timeout=120s >/dev/null
  ok "System pods moved to the platform node"
}

install_metrics_server() {
  log "Installing metrics-server"
  kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml" >/dev/null
  # Full arg list (not an append) so re-runs stay idempotent. kind's kubelets
  # use self-signed serving certificates, hence --kubelet-insecure-tls.
  kubectl -n kube-system patch deployment metrics-server --type=json -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/args","value":[
      "--cert-dir=/tmp","--secure-port=10250",
      "--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname",
      "--kubelet-use-node-status-port","--metric-resolution=15s","--kubelet-insecure-tls"]}]' >/dev/null
  pin_to_platform kube-system metrics-server
  kubectl -n kube-system rollout status deployment metrics-server --timeout=180s >/dev/null
  ok "metrics-server ready"
}

# Recommender only: we never let VPA change pods, so the updater and admission
# controller aren't needed. Its default minimums (25m / 250Mi) are larger than our
# small services, so we lower them, and we right-size the recommender itself.
install_vpa_recommender() {
  log "Installing the VPA recommender"
  local base="https://raw.githubusercontent.com/kubernetes/autoscaler/${VPA_TAG}/vertical-pod-autoscaler/deploy"
  local f
  for f in vpa-v1-crd-gen.yaml vpa-rbac.yaml recommender-deployment.yaml; do
    kubectl apply -f "${base}/${f}" >/dev/null || die "Could not install VPA (${f})."
  done
  kubectl -n kube-system patch deployment vpa-recommender --type=json -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/args","value":[
      "--pod-recommendation-min-cpu-millicores=10","--pod-recommendation-min-memory-mb=16"]},
    {"op":"add","path":"/spec/template/spec/containers/0/resources","value":{
      "requests":{"cpu":"25m","memory":"128Mi"},"limits":{"memory":"256Mi"}}}]' >/dev/null
  pin_to_platform kube-system vpa-recommender
  kubectl -n kube-system rollout status deployment vpa-recommender --timeout=180s >/dev/null
  kubectl wait --for=condition=Established crd/verticalpodautoscalers.autoscaling.k8s.io --timeout=60s >/dev/null
  ok "VPA recommender ready"
}

enough_app_pods_running() {
  (( $(running_pods "") >= EXPECTED_RUNNING_PODS ))
}

shop_already_deployed() {
  kubectl get deployments -n "${APP_NAMESPACE}" -o name 2>/dev/null | grep -q .
}

deploy_workloads() {
  kubectl apply -f "${REPO_ROOT}/load/" >/dev/null
  if shop_already_deployed; then
    ok "Shop already deployed, keeping your current lab state (./catchup.sh <lab> resets it)"
    return
  fi
  log "Deploying the shop (bloated) and the load generator"
  kubectl apply -k "${REPO_ROOT}/app/bloated" >/dev/null
  kubectl -n "${LOAD_NAMESPACE}" rollout status deployment loadgen --timeout=180s >/dev/null
  wait_for "${APP_READY_TIMEOUT_S}" enough_app_pods_running \
    || die "Shop pods didn't start in time. Check: kubectl get pods -n ${APP_NAMESPACE}"
  ok "Shop deployed: $(running_pods "") pods running"
}

main() {
  local start; start=$(date +%s)
  preflight
  create_cluster
  label_nodes
  move_system_pods
  install_metrics_server
  install_vpa_recommender
  deploy_workloads
  printf '\n'
  ok "Setup finished in $(( $(date +%s) - start ))s. You're ready for Lab 1."
}

main "$@"
