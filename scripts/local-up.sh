#!/usr/bin/env bash
# local-up.sh — build the local k3d cluster that mirrors the E2E GPU cluster.
#
# Same k3s version as E2E, 4 fake nvidia.com/gpu on the server node (the L4
# time-sliced x4), RuntimeClass "nvidia" (-> runc), kube-prometheus-stack, and a
# local registry so `ko` images reach the cluster. CPU vLLM runs on top of this.
#
# Usage (from the repo root, or via make):
#   scripts/local-up.sh                      # create or start the cluster; safe to re-run (make local-up)
#   scripts/local-up.sh down                 # delete the cluster and its registry (make local-down)
#   scripts/local-up.sh add-node gpu-2 1     # phase 6: add an agent node with 1 fake GPU
#
# Optional environment variables:
#   K3S_VERSION=v1.35.5+k3s1     keep in step with bootstrap-gpu-node.sh
#   HTTP_PORT=8080               Mac port for the cluster's ingress (port 80)
#   REGISTRY_PORT=5111           Mac port for the local image registry
#   FAKE_GPUS=4                  nvidia.com/gpu advertised on the server node
#   KPS_VERSION=                 pin the kube-prometheus-stack chart version
#   SKIP_MONITORING=1            don't install kube-prometheus-stack

set -euo pipefail

CLUSTER=tinyinfer
CTX="k3d-$CLUSTER"
K3S_VERSION="${K3S_VERSION:-v1.35.5+k3s1}"
HTTP_PORT="${HTTP_PORT:-8080}"
REGISTRY_NAME="$CLUSTER-registry"
REGISTRY_PORT="${REGISTRY_PORT:-5111}"
FAKE_GPUS="${FAKE_GPUS:-4}"
KPS_VERSION="${KPS_VERSION:-}"
SKIP_MONITORING="${SKIP_MONITORING:-0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAKE_GPU_LABEL="tinyinfer.dev/fake-gpus"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN:\033[0m %s\n' "$*" >&2; }
fail() { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
# Always name the context, so nothing here can touch the E2E cluster by accident.
kc()   { kubectl --context "$CTX" "$@"; }

cluster_exists() { k3d cluster list "$CLUSTER" >/dev/null 2>&1; }

# Advertise N fake GPUs on a node: a JSON patch to the node's status subresource,
# the "advertise extended resources for a node" method. The NVIDIA device plugin
# does this for real on E2E. The label records the count so re-runs can restore it.
advertise_gpus() {
  local node="$1" count="$2"
  kc label node "$node" "$FAKE_GPU_LABEL=$count" nvidia.com/gpu.present=true --overwrite >/dev/null
  kc patch node "$node" --subresource=status --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/status/capacity/nvidia.com~1gpu\",\"value\":\"$count\"}]" >/dev/null
  # The kubelet copies capacity into allocatable on its next status update (~10 s).
  local alloc=""
  for _ in $(seq 1 30); do
    alloc=$(kc get node "$node" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')
    [ "$alloc" = "$count" ] && break
    sleep 2
  done
  [ "$alloc" = "$count" ] || fail "$node: allocatable nvidia.com/gpu is '${alloc}', expected $count"
  echo "$node: allocatable nvidia.com/gpu = $alloc"
}

# Re-apply fake GPUs on every node that has the label (after a restart the
# kubelet may reset extended resources it doesn't manage).
restore_gpus() {
  local node count
  for node in $(kc get nodes -l "$FAKE_GPU_LABEL" -o name | cut -d/ -f2); do
    count=$(kc get node "$node" -o jsonpath="{.metadata.labels.tinyinfer\.dev/fake-gpus}")
    advertise_gpus "$node" "$count"
  done
}

for tool in docker k3d kubectl helm jq; do
  command -v "$tool" >/dev/null || fail "$tool not found (brew install $tool)"
done
docker info >/dev/null 2>&1 || fail "Docker is not running"

# ---------------------------------------------------------------------------
case "${1:-up}" in
down)
  if cluster_exists; then k3d cluster delete "$CLUSTER"; else echo "no cluster '$CLUSTER'"; fi
  exit 0
  ;;
add-node)
  name="${2:?usage: $0 add-node <name> <fake-gpus>}"
  count="${3:-1}"
  cluster_exists || fail "cluster '$CLUSTER' does not exist; run $0 first"
  log "Adding agent node '$name' with $count fake GPU(s)"
  k3d node create "$name" --cluster "$CLUSTER" --role agent \
    --image "rancher/k3s:${K3S_VERSION/+/-}" --wait
  node="k3d-$name-0"
  kc wait --for=condition=Ready "node/$node" --timeout=120s
  advertise_gpus "$node" "$count"
  exit 0
  ;;
up) ;;
*) sed -n '2,20p' "$0"; exit 1 ;;
esac

START=$(date +%s)

# ---------------------------------------------------------------------------
log "1/5 Docker resources"
MEM_GIB=$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 / 1024 ))
CPUS=$(docker info --format '{{.NCPU}}')
echo "Docker VM: ${CPUS} CPUs, ${MEM_GIB} GiB"
[ "$MEM_GIB" -ge 13 ] || warn "two CPU vLLM replicas need a 14-16 GiB Docker VM; you have ${MEM_GIB} GiB"
OTHERS=$(k3d cluster list -o json | jq -r --arg c "$CLUSTER" '.[] | select(.name != $c and .serversRunning > 0) | .name')
[ -z "$OTHERS" ] || warn "other k3d clusters are running and share that memory: $(echo $OTHERS) (k3d cluster stop <name>)"

# ---------------------------------------------------------------------------
log "2/5 k3d cluster '$CLUSTER' (k3s $K3S_VERSION)"
if cluster_exists; then
  echo "exists; starting it (no-op if running)"
  k3d cluster start "$CLUSTER" --wait
else
  if lsof -iTCP:"$HTTP_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    fail "port $HTTP_PORT is in use (another k3d cluster's load balancer?). Stop it, or run HTTP_PORT=<free port> $0"
  fi
  # Let pods pull "localhost:$REGISTRY_PORT/..." exactly as `ko` pushes it from
  # the Mac: containerd in the node is told that name means the registry container.
  REG_CFG=$(mktemp)
  trap 'rm -f "$REG_CFG"' EXIT
  cat > "$REG_CFG" <<EOF
mirrors:
  "localhost:$REGISTRY_PORT":
    endpoint:
      - http://k3d-$REGISTRY_NAME:5000
EOF
  CONFIG_ARGS=()
  [ -f "$ROOT/deploy/local/k3d.yaml" ] && CONFIG_ARGS=(--config "$ROOT/deploy/local/k3d.yaml")
  k3d cluster create "$CLUSTER" ${CONFIG_ARGS[@]+"${CONFIG_ARGS[@]}"} \
    --servers 1 \
    --image "rancher/k3s:${K3S_VERSION/+/-}" \
    -p "$HTTP_PORT:80@loadbalancer" \
    --registry-create "k3d-$REGISTRY_NAME:0.0.0.0:$REGISTRY_PORT" \
    --registry-config "$REG_CFG" \
    --kubeconfig-update-default --kubeconfig-switch-context=false \
    --wait
fi
kc wait --for=condition=Ready node --all --timeout=180s

# ---------------------------------------------------------------------------
log "3/5 Fake GPUs"
SERVER_NODE="k3d-$CLUSTER-server-0"
if [ -z "$(kc get node "$SERVER_NODE" -o jsonpath="{.metadata.labels.tinyinfer\.dev/fake-gpus}")" ]; then
  kc label node "$SERVER_NODE" "$FAKE_GPU_LABEL=$FAKE_GPUS" >/dev/null
fi
restore_gpus

# ---------------------------------------------------------------------------
log "4/5 Cluster manifests"
if [ -f "$ROOT/deploy/local/runtimeclass.yaml" ]; then
  kc apply -f "$ROOT/deploy/local/runtimeclass.yaml"
else
  warn "deploy/local/runtimeclass.yaml not written yet (RuntimeClass 'nvidia' -> runc); GPU pods won't schedule without it"
fi
# Redis, Postgres, vLLM and the gateway come from the Helm chart: make deploy ENV=local

# ---------------------------------------------------------------------------
if [ "$SKIP_MONITORING" != "1" ]; then
  log "5/5 kube-prometheus-stack (namespace monitoring)"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
  helm repo update prometheus-community >/dev/null
  VERSION_ARGS=()
  [ -n "$KPS_VERSION" ] && VERSION_ARGS=(--version "$KPS_VERSION")
  # *NilUsesHelmValues=false: Prometheus picks up every ServiceMonitor/PodMonitor/rule
  #   in the cluster, not only ones labelled for this release (phase 7 adds ours).
  # hostRootFsMount=false: node-exporter can't mount / inside a k3d node container.
  helm --kube-context "$CTX" upgrade -i kps prometheus-community/kube-prometheus-stack \
    ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"} \
    -n monitoring --create-namespace \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.retention=2d \
    --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
    --set prometheus-node-exporter.hostRootFsMount.enabled=false \
    --set grafana.resources.requests.memory=128Mi \
    --wait --timeout 10m
  helm --kube-context "$CTX" list -n monitoring
else
  log "5/5 kube-prometheus-stack skipped"
fi

# ---------------------------------------------------------------------------
ELAPSED=$(( $(date +%s) - START ))
cat <<EOF

$(printf '\033[32m')Local cluster ready in $((ELAPSED / 60))m$((ELAPSED % 60))s.$(printf '\033[0m')
  context:   $CTX           (kubectl --context $CTX ... or kubectl config use-context $CTX)
  ingress:   http://localhost:$HTTP_PORT
  registry:  localhost:$REGISTRY_PORT  (KO_DOCKER_REPO for make deploy ENV=local)
  grafana:   kubectl --context $CTX -n monitoring port-forward svc/kps-grafana 3000:80
             user admin, password: kubectl --context $CTX -n monitoring get secret kps-grafana -o jsonpath='{.data.admin-password}' | base64 -d
EOF
