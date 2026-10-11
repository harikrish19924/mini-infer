#!/usr/bin/env bash
# bootstrap-gpu-node.sh — turn a fresh E2E GPU node (Ubuntu) into a single-node
# k3s cluster with a schedulable, time-sliced NVIDIA GPU, and optionally a vLLM model.
#
# Usage (on the GPU node, as root):
#   bash bootstrap-gpu-node.sh               # GPU cluster only (steps 1-7)
#   bash bootstrap-gpu-node.sh --with-vllm   # + deploy and test a small vLLM model (step 8)
#
# Optional environment variables:
#   TS_REPLICAS=4                     pods that may share the GPU (time-slicing)
#   K3S_VERSION=v1.xx.x+k3s1          pin k3s (default: latest stable)
#   VLLM_TAG=latest                   vllm/vllm-openai image tag — PIN THIS for benchmarks
#   VLLM_MODEL=Qwen/Qwen2.5-1.5B-Instruct
#   VLLM_NAME=qwen-1.5b               served model name clients use
#   SKIP_SMOKE_TEST=1                 skip the nvidia-smi test pod
#
# Safe to re-run: every step checks first, or upgrades in place.

set -euo pipefail

WITH_VLLM=0
for arg in "$@"; do
  case "$arg" in
    --with-vllm) WITH_VLLM=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
  esac
done

TS_REPLICAS="${TS_REPLICAS:-4}"
K3S_VERSION="${K3S_VERSION:-}"
SKIP_SMOKE_TEST="${SKIP_SMOKE_TEST:-0}"
VLLM_TAG="${VLLM_TAG:-latest}"
VLLM_MODEL="${VLLM_MODEL:-Qwen/Qwen2.5-1.5B-Instruct}"
VLLM_NAME="${VLLM_NAME:-qwen-1.5b}"
CUDA_TEST_IMAGE="nvidia/cuda:12.4.1-base-ubuntu22.04"
WORKDIR=/root/tinyinfer
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

STEPS=7; [ "$WITH_VLLM" = "1" ] && STEPS=8
log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
START=$(date +%s)

[ "$(id -u)" -eq 0 ] || fail "Run as root: sudo -i, then bash $0"
command -v apt-get >/dev/null || fail "This script expects an Ubuntu/Debian image."
mkdir -p "$WORKDIR"

# ---------------------------------------------------------------------------
log "1/$STEPS Checking the NVIDIA driver (waits up to 5 min; GPU nodes initialise on first boot)"
for _ in $(seq 1 30); do nvidia-smi >/dev/null 2>&1 && break; sleep 10; done
if ! nvidia-smi >/dev/null 2>&1; then
  fail "nvidia-smi does not work. Install a driver, reboot, and re-run:
    apt-get update && apt-get install -y ubuntu-drivers-common
    ubuntu-drivers install
    reboot"
fi
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv

# ---------------------------------------------------------------------------
log "2/$STEPS Base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl gnupg ca-certificates jq

# ---------------------------------------------------------------------------
log "3/$STEPS NVIDIA container toolkit (must be installed BEFORE k3s starts)"
if ! dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -y
  apt-get install -y nvidia-container-toolkit
else
  echo "already installed: $(nvidia-ctk --version | head -n 1)"
fi

# ---------------------------------------------------------------------------
log "4/$STEPS k3s"
if ! command -v k3s >/dev/null 2>&1; then
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - --write-kubeconfig-mode 644
else
  echo "k3s already installed: $(k3s --version | head -n 1); restarting so it re-detects the NVIDIA runtime"
  systemctl restart k3s
fi
for _ in $(seq 1 30); do kubectl get nodes >/dev/null 2>&1 && break; sleep 5; done
kubectl wait --for=condition=Ready node --all --timeout=180s

# Make kubectl/helm find the cluster in every future root shell
grep -qxF "export KUBECONFIG=$KUBECONFIG" /root/.bashrc 2>/dev/null \
  || echo "export KUBECONFIG=$KUBECONFIG" >> /root/.bashrc

CONTAINERD_CFG=/var/lib/rancher/k3s/agent/etc/containerd/config.toml
if grep -qi nvidia "$CONTAINERD_CFG" 2>/dev/null; then
  echo "containerd has an nvidia runtime entry"
else
  fail "k3s did not detect the NVIDIA runtime ($CONTAINERD_CFG). Check 'which nvidia-container-runtime', then: systemctl restart k3s"
fi

# ---------------------------------------------------------------------------
log "5/$STEPS RuntimeClass 'nvidia'"
if kubectl get runtimeclass nvidia >/dev/null 2>&1; then
  echo "already present"
else
  kubectl apply -f - <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOF
fi

# ---------------------------------------------------------------------------
log "6/$STEPS Helm + NVIDIA device plugin with time-slicing x${TS_REPLICAS}"
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# The chart only schedules on nodes labelled as having an NVIDIA GPU. That label
# normally comes from Node Feature Discovery, which we don't install, so add it.
kubectl label nodes --all nvidia.com/gpu.present=true --overwrite

cat > "$WORKDIR/time-slicing.yaml" <<EOF
version: v1
sharing:
  timeSlicing:
    resources:
    - name: nvidia.com/gpu
      replicas: ${TS_REPLICAS}
EOF

helm repo add nvdp https://nvidia.github.io/k8s-device-plugin >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade -i nvdp nvdp/nvidia-device-plugin \
  -n nvidia-device-plugin --create-namespace \
  --set runtimeClassName=nvidia \
  --set config.default=config \
  --set-file config.map.config="$WORKDIR/time-slicing.yaml" \
  --wait --timeout 10m

echo "waiting for nvidia.com/gpu to appear on the node (up to 5 min)..."
GPUS=""
for _ in $(seq 1 60); do
  GPUS=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)
  [ -n "$GPUS" ] && [ "$GPUS" != "0" ] && break
  sleep 5
done
if [ -z "$GPUS" ] || [ "$GPUS" = "0" ]; then
  kubectl -n nvidia-device-plugin get pods -o wide || true
  fail "nvidia.com/gpu never became allocatable. Check: kubectl -n nvidia-device-plugin logs -l app.kubernetes.io/name=nvidia-device-plugin --all-containers"
fi
echo "allocatable nvidia.com/gpu = ${GPUS}"

# ---------------------------------------------------------------------------
if [ "$SKIP_SMOKE_TEST" != "1" ]; then
  log "7/$STEPS Smoke test: running nvidia-smi inside a pod"
  kubectl delete pod gpu-smoke --ignore-not-found >/dev/null
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: gpu-smoke
spec:
  restartPolicy: Never
  runtimeClassName: nvidia
  containers:
  - name: cuda
    image: ${CUDA_TEST_IMAGE}
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
EOF
  PHASE=""
  for _ in $(seq 1 60); do
    PHASE=$(kubectl get pod gpu-smoke -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ "$PHASE" = "Succeeded" ] || [ "$PHASE" = "Failed" ]; then break; fi
    sleep 5
  done
  kubectl logs gpu-smoke || true
  [ "$PHASE" = "Succeeded" ] || fail "GPU test pod ended in phase '${PHASE:-unknown}'. Inspect: kubectl describe pod gpu-smoke"
  kubectl delete pod gpu-smoke >/dev/null
else
  log "7/$STEPS Smoke test skipped"
fi

# ---------------------------------------------------------------------------
if [ "$WITH_VLLM" = "1" ]; then
  log "8/$STEPS vLLM: ${VLLM_MODEL} as '${VLLM_NAME}' (image vllm/vllm-openai:${VLLM_TAG})"
  [ "$VLLM_TAG" = "latest" ] && echo "  note: pin VLLM_TAG to a release tag before you benchmark"

  cat > "$WORKDIR/vllm.yaml" <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hf-cache
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 30Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm
  labels: { app: vllm }
spec:
  replicas: 1
  selector:
    matchLabels: { app: vllm }
  template:
    metadata:
      labels: { app: vllm }
    spec:
      runtimeClassName: nvidia
      containers:
      - name: vllm
        image: vllm/vllm-openai:${VLLM_TAG}
        command: ["/bin/sh", "-c"]
        args:
        - >-
          vllm serve ${VLLM_MODEL}
          --served-model-name ${VLLM_NAME}
          --max-model-len 4096
          --gpu-memory-utilization 0.4
          --enable-prefix-caching
        ports:
        - containerPort: 8000
        resources:
          limits:
            nvidia.com/gpu: 1
        volumeMounts:
        - { name: shm, mountPath: /dev/shm }
        - { name: hf-cache, mountPath: /root/.cache/huggingface }
        startupProbe:
          httpGet: { path: /health, port: 8000 }
          periodSeconds: 10
          failureThreshold: 90
        readinessProbe:
          httpGet: { path: /health, port: 8000 }
          periodSeconds: 5
      volumes:
      - name: shm
        emptyDir: { medium: Memory, sizeLimit: 2Gi }
      - name: hf-cache
        persistentVolumeClaim: { claimName: hf-cache }
---
apiVersion: v1
kind: Service
metadata:
  name: vllm
spec:
  selector: { app: vllm }
  ports:
  - port: 8000
    targetPort: 8000
EOF
  kubectl apply -f "$WORKDIR/vllm.yaml"

  echo "waiting for vLLM to pull, download weights and start (first time: several minutes)..."
  echo "  follow along in another shell: kubectl logs -f deploy/vllm"
  kubectl rollout status deploy/vllm --timeout=20m \
    || fail "vLLM did not become ready. Inspect: kubectl describe pod -l app=vllm ; kubectl logs deploy/vllm"

  kubectl port-forward svc/vllm 18000:8000 >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill $PF_PID 2>/dev/null || true' EXIT
  sleep 3
  echo "models:"
  curl -fsS localhost:18000/v1/models | jq -r '.data[].id'
  echo "chat test:"
  curl -fsS localhost:18000/v1/chat/completions -H 'Content-Type: application/json' \
    -d "{\"model\":\"${VLLM_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: GPU cluster ready\"}],\"max_tokens\":20}" \
    | jq -r '.choices[0].message.content'
  kill "$PF_PID" 2>/dev/null || true
  trap - EXIT
fi

# ---------------------------------------------------------------------------
ELAPSED=$(( ($(date +%s) - START) / 60 ))
NODE_IP=$(curl -s --max-time 5 https://ifconfig.me || hostname -I | awk '{print $1}')
cat <<EOF

$(printf '\033[32m')GPU cluster is ready in ~${ELAPSED} min.$(printf '\033[0m')  GPU slots: ${GPUS}$( [ "$WITH_VLLM" = "1" ] && echo ", vLLM model: ${VLLM_NAME}")
Manifests written to: ${WORKDIR}/

From your laptop (or use new-session.sh, which does this for you):
  scp root@${NODE_IP}:/etc/rancher/k3s/k3s.yaml ~/.kube/tinyinfer.yaml
  ssh -N -L 6443:127.0.0.1:6443 root@${NODE_IP}     # keep open
  export KUBECONFIG=~/.kube/tinyinfer.yaml && kubectl get nodes

Remember: DELETE the node in MyAccount when you finish the session.
EOF
