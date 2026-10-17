#!/usr/bin/env bash
# new-session.sh — run on your LAPTOP after creating a fresh E2E GPU node.
# Copies the bootstrap script to the node, runs it, fetches the kubeconfig and
# opens an SSH tunnel so kubectl/helm work from the laptop.
#
# Usage:
#   ./new-session.sh <node-public-ip> [--with-vllm]
#   ./new-session.sh stop            # close the tunnel at the end of a session
#
# Optional environment variables:
#   NODE_USER=root                   login user on the node
#   SSH_KEY=~/.ssh/e2e_gpu           private key matching the one added to E2E
#   BOOTSTRAP=./bootstrap-gpu-node.sh
#   KUBECONFIG_OUT=~/.kube/tinyinfer.yaml   where the cluster's kubeconfig is written
#   TUNNEL_SOCKET=~/.ssh/tinyinfer-tunnel.sock
#   VLLM_TAG / VLLM_MODEL / VLLM_NAME / TS_REPLICAS / K3S_VERSION / SKIP_GPU   passed through to the node

set -euo pipefail

NODE_USER="${NODE_USER:-root}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/e2e_gpu}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOOTSTRAP="${BOOTSTRAP:-$SCRIPT_DIR/bootstrap-gpu-node.sh}"
KUBECONFIG_OUT="${KUBECONFIG_OUT:-$HOME/.kube/tinyinfer.yaml}"
TUNNEL_SOCKET="${TUNNEL_SOCKET:-$HOME/.ssh/tinyinfer-tunnel.sock}"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

stop_tunnel() {
  if [ -S "$TUNNEL_SOCKET" ]; then
    ssh -S "$TUNNEL_SOCKET" -O exit tinyinfer-node 2>/dev/null || true
    rm -f "$TUNNEL_SOCKET"
    echo "tunnel closed"
  else
    echo "no tunnel running"
  fi
}

[ $# -ge 1 ] || { sed -n '2,17p' "$0"; exit 1; }
if [ "$1" = "stop" ]; then
  stop_tunnel
  echo "Now DELETE the node in E2E MyAccount (Compute → Nodes → Delete)."
  exit 0
fi

NODE_IP="$1"; shift
BOOT_ARGS=""
for arg in "$@"; do
  case "$arg" in
    --with-vllm) BOOT_ARGS="--with-vllm" ;;
    *) fail "Unknown option: $arg" ;;
  esac
done

[ -f "$SSH_KEY" ] || fail "SSH key $SSH_KEY not found (run install-dev-tools.sh, or set SSH_KEY=...)"
[ -f "$BOOTSTRAP" ] || fail "bootstrap script not found at $BOOTSTRAP (set BOOTSTRAP=...)"
command -v kubectl >/dev/null || fail "kubectl not installed on this laptop (run install-dev-tools.sh)"

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ConnectTimeout=10)
TARGET="$NODE_USER@$NODE_IP"

# ---------------------------------------------------------------------------
log "1/5 Preparing SSH to $TARGET"
# A new node may reuse an old IP with a new host key; forget the old one.
ssh-keygen -R "$NODE_IP" >/dev/null 2>&1 || true
for i in $(seq 1 30); do
  if ssh "${SSH_OPTS[@]}" "$TARGET" true 2>/dev/null; then echo "SSH is up"; break; fi
  [ "$i" -eq 30 ] && fail "Cannot SSH to $TARGET. Check: node is Running, security group allows TCP 22 from your current IP, user/key are right."
  echo "waiting for SSH... ($i/30)"; sleep 10
done

# ---------------------------------------------------------------------------
log "2/5 Copying bootstrap script"
# Into the login user's home: a non-root NODE_USER can't write to /root
scp "${SSH_OPTS[@]}" "$BOOTSTRAP" "$TARGET:bootstrap-gpu-node.sh"

# ---------------------------------------------------------------------------
log "3/5 Running bootstrap on the node (10-20 min the first time)"
REMOTE_ENV=""
for v in VLLM_TAG VLLM_MODEL VLLM_NAME TS_REPLICAS K3S_VERSION SKIP_GPU; do
  if [ -n "${!v:-}" ]; then REMOTE_ENV="$REMOTE_ENV $v=$(printf '%q' "${!v}")"; fi
done
SUDO=""; [ "$NODE_USER" != "root" ] && SUDO="sudo"
# -t gives live, coloured output from the node
ssh -t "${SSH_OPTS[@]}" "$TARGET" "$SUDO env $REMOTE_ENV bash bootstrap-gpu-node.sh $BOOT_ARGS"

# ---------------------------------------------------------------------------
log "4/5 Fetching kubeconfig to $KUBECONFIG_OUT"
mkdir -p "$HOME/.kube"
scp "${SSH_OPTS[@]}" "$TARGET:/etc/rancher/k3s/k3s.yaml" "$KUBECONFIG_OUT"
chmod 600 "$KUBECONFIG_OUT"

# ---------------------------------------------------------------------------
log "5/5 Opening SSH tunnel (laptop :6443 -> node 127.0.0.1:6443)"
stop_tunnel >/dev/null 2>&1 || true
if lsof -iTCP:6443 -sTCP:LISTEN >/dev/null 2>&1; then
  fail "Port 6443 is already in use on this laptop (an old tunnel?). Close it and re-run step 5: ./new-session.sh stop"
fi
ssh "${SSH_OPTS[@]}" -f -N -M -S "$TUNNEL_SOCKET" -L 6443:127.0.0.1:6443 "$TARGET"
sleep 2
KUBECONFIG="$KUBECONFIG_OUT" kubectl get nodes \
  || fail "Tunnel is up but kubectl cannot reach the cluster."

cat <<EOF

$(printf '\033[32m')Session ready.$(printf '\033[0m')
In every new terminal on this laptop:
  export KUBECONFIG=$KUBECONFIG_OUT
  kubectl get pods -A
$( [ -n "$BOOT_ARGS" ] && echo "  kubectl port-forward svc/vllm 8000:8000   # then curl localhost:8000/v1/models" )

When you're done:
  ./new-session.sh stop          # closes the tunnel
  then DELETE the node in E2E MyAccount.
EOF
