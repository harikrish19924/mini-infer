#!/usr/bin/env bash
# join-gpu-node.sh — run on your LAPTOP to add a second E2E GPU node to the
# cluster that new-session.sh built (run C6, and the C8 big GPU).
# Reads the join token and k3s version from the server, runs bootstrap-gpu-node.sh
# on the new node as a k3s agent, then labels it and waits for its GPUs.
#
# Usage:
#   ./join-gpu-node.sh <server-public-ip> <agent-public-ip>
#
# Before running, in E2E MyAccount allow these between the two nodes' PRIVATE
# IPs only: TCP 6443 (API server), UDP 8472 (flannel VXLAN), TCP 10250 (kubelet).
#
# Optional environment variables:
#   NODE_USER=root                   login user on both nodes
#   SSH_KEY=~/.ssh/e2e_gpu
#   SERVER_PRIVATE_IP=               address the agent uses to reach the server
#                                    (default: the server node's InternalIP in k3s)
#   BOOTSTRAP=./bootstrap-gpu-node.sh
#   SKIP_GPU=1                       GPU-less test VMs (vm-test.sh)

set -euo pipefail

NODE_USER="${NODE_USER:-root}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/e2e_gpu}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOOTSTRAP="${BOOTSTRAP:-$SCRIPT_DIR/bootstrap-gpu-node.sh}"
SERVER_PRIVATE_IP="${SERVER_PRIVATE_IP:-}"
SKIP_GPU="${SKIP_GPU:-0}"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ $# -eq 2 ] || { sed -n '2,20p' "$0"; exit 1; }
SERVER_IP="$1"; AGENT_IP="$2"
[ -f "$SSH_KEY" ] || fail "SSH key $SSH_KEY not found (set SSH_KEY=...)"
[ -f "$BOOTSTRAP" ] || fail "bootstrap script not found at $BOOTSTRAP (set BOOTSTRAP=...)"

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ConnectTimeout=10)
SUDO=""; [ "$NODE_USER" != "root" ] && SUDO="sudo"
on_server() { ssh "${SSH_OPTS[@]}" "$NODE_USER@$SERVER_IP" "$@"; }
on_agent()  { ssh "${SSH_OPTS[@]}" "$NODE_USER@$AGENT_IP" "$@"; }
# kubectl on the server itself, so this works with or without the laptop tunnel
skubectl()  { on_server "$SUDO k3s kubectl $*"; }

# ---------------------------------------------------------------------------
log "1/5 SSH to both nodes"
ssh-keygen -R "$AGENT_IP" >/dev/null 2>&1 || true
on_server true || fail "Cannot SSH to the server $NODE_USER@$SERVER_IP"
for i in $(seq 1 30); do
  if on_agent true 2>/dev/null; then echo "SSH is up on both"; break; fi
  [ "$i" -eq 30 ] && fail "Cannot SSH to the new node $NODE_USER@$AGENT_IP"
  echo "waiting for SSH on the new node... ($i/30)"; sleep 10
done

# ---------------------------------------------------------------------------
log "2/5 Reading join details from the server"
TOKEN=$(on_server "$SUDO cat /var/lib/rancher/k3s/server/node-token") \
  || fail "No k3s server on $SERVER_IP (run new-session.sh against it first)"
K3S_VERSION=$(on_server "k3s --version" | awk 'NR==1 {print $3}')
if [ -z "$SERVER_PRIVATE_IP" ]; then
  SERVER_PRIVATE_IP=$(skubectl get nodes -l node-role.kubernetes.io/control-plane=true \
    -o "jsonpath='{.items[0].status.addresses[?(@.type==\"InternalIP\")].address}'")
fi
[ -n "$SERVER_PRIVATE_IP" ] || fail "Could not find the server's private IP (set SERVER_PRIVATE_IP=...)"
AGENT_NAME=$(on_agent hostname)
echo "server: $SERVER_PRIVATE_IP (k3s $K3S_VERSION); new node: $AGENT_NAME"
skubectl get node "$AGENT_NAME" >/dev/null 2>&1 && echo "note: $AGENT_NAME is already in the cluster; re-running the join"

# ---------------------------------------------------------------------------
log "3/5 Bootstrapping the new node as a k3s agent"
scp "${SSH_OPTS[@]}" "$BOOTSTRAP" "$NODE_USER@$AGENT_IP:bootstrap-gpu-node.sh"
# The token goes over stdin, so it stays out of the laptop's ssh command line and shell history.
printf '%s' "$TOKEN" | ssh "${SSH_OPTS[@]}" "$NODE_USER@$AGENT_IP" \
  "TOKEN=\$(cat); $SUDO env K3S_URL=https://$SERVER_PRIVATE_IP:6443 K3S_TOKEN=\"\$TOKEN\" K3S_VERSION=$K3S_VERSION SKIP_GPU=$SKIP_GPU bash bootstrap-gpu-node.sh"

# ---------------------------------------------------------------------------
log "4/5 Waiting for $AGENT_NAME to be Ready"
for i in $(seq 1 36); do
  skubectl get node "$AGENT_NAME" >/dev/null 2>&1 && break
  [ "$i" -eq 36 ] && fail "$AGENT_NAME never registered. On the node: journalctl -u k3s-agent -n 50 (firewall: TCP 6443 to the server?)"
  sleep 5
done
skubectl wait --for=condition=Ready "node/$AGENT_NAME" --timeout=180s \
  || fail "$AGENT_NAME is not Ready. Check UDP 8472 and TCP 10250 between the nodes' private IPs."

# ---------------------------------------------------------------------------
if [ "$SKIP_GPU" = "1" ]; then
  log "5/5 GPU labelling skipped (SKIP_GPU=1)"
  GPUS="none (SKIP_GPU)"
else
  log "5/5 Labelling $AGENT_NAME so the NVIDIA device plugin runs on it"
  skubectl label node "$AGENT_NAME" nvidia.com/gpu.present=true --overwrite
  GPUS=""
  for _ in $(seq 1 60); do
    GPUS=$(skubectl get node "$AGENT_NAME" -o "jsonpath='{.status.allocatable.nvidia\.com/gpu}'" 2>/dev/null || true)
    [ -n "$GPUS" ] && [ "$GPUS" != "0" ] && break
    sleep 5
  done
  [ -n "$GPUS" ] && [ "$GPUS" != "0" ] \
    || fail "nvidia.com/gpu never became allocatable on $AGENT_NAME. Check: k3s kubectl -n nvidia-device-plugin get pods -o wide"
fi

skubectl get nodes -o wide
cat <<EOF

$(printf '\033[32m')$AGENT_NAME joined.$(printf '\033[0m')  allocatable nvidia.com/gpu: $GPUS
The time-slicing config applies to every node. For C6 (one replica per GPU),
change TS_REPLICAS / the device-plugin config, or pin replicas with anti-affinity.

When you're done: DELETE BOTH nodes in E2E MyAccount.
EOF
