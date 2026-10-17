#!/usr/bin/env bash
# vm-test.sh — test the E2E scripts before paying for a GPU node.
# Starts two Ubuntu VMs with Multipass, then runs the real laptop-side flow
# against them with every NVIDIA step skipped (SKIP_GPU=1):
#   new-session.sh  -> bootstrap the server VM, fetch kubeconfig, open the tunnel
#   join-gpu-node.sh -> join the second VM as a k3s agent
# and checks that both nodes are Ready and RuntimeClass "nvidia" exists.
#
# Usage:
#   scripts/vm-test.sh            # test, then delete the VMs
#   scripts/vm-test.sh --rerun    # also re-run the bootstrap on the server (checks it is idempotent)
#   scripts/vm-test.sh --keep     # leave the VMs and tunnel up afterwards for poking around
#
# Needs: brew install --cask multipass. Your real ~/.kube/tinyinfer.yaml and
# E2E SSH key are never touched; a throwaway key and kubeconfig are used.

set -euo pipefail

RERUN=0; KEEP=0
for arg in "$@"; do
  case "$arg" in
    --rerun) RERUN=1 ;;
    --keep)  KEEP=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
  esac
done

SERVER_VM=ti-server
AGENT_VM=ti-agent
UBUNTU="${UBUNTU:-24.04}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK=$(mktemp -d)

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

for tool in multipass jq kubectl ssh-keygen; do
  command -v "$tool" >/dev/null || fail "$tool not found (multipass: brew install --cask multipass)"
done
for vm in "$SERVER_VM" "$AGENT_VM"; do
  multipass info "$vm" >/dev/null 2>&1 && fail "VM $vm already exists (multipass delete --purge $vm)"
done

# Settings shared by new-session.sh and join-gpu-node.sh
export NODE_USER=ubuntu
export SSH_KEY="$WORK/id_ed25519"
export SKIP_GPU=1
export KUBECONFIG_OUT="$WORK/kubeconfig"
export TUNNEL_SOCKET="$WORK/tunnel.sock"

cleanup() {
  local status=$?
  if [ "$KEEP" = "1" ]; then
    cat <<EOF

VMs kept. Tunnel and kubeconfig:
  export KUBECONFIG=$KUBECONFIG_OUT
  multipass shell $SERVER_VM
Clean up later:
  TUNNEL_SOCKET=$TUNNEL_SOCKET $SCRIPT_DIR/new-session.sh stop
  multipass delete --purge $SERVER_VM $AGENT_VM
EOF
    exit "$status"
  fi
  log "Cleaning up"
  "$SCRIPT_DIR/new-session.sh" stop >/dev/null 2>&1 || true
  multipass delete --purge "$SERVER_VM" "$AGENT_VM" 2>/dev/null || true
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT

START=$(date +%s)

# ---------------------------------------------------------------------------
log "1/5 Launching $SERVER_VM and $AGENT_VM (Ubuntu $UBUNTU)"
ssh-keygen -q -t ed25519 -N "" -C tinyinfer-vm-test -f "$SSH_KEY"
cat > "$WORK/cloud-init.yaml" <<EOF
#cloud-config
ssh_authorized_keys:
  - $(cat "$SSH_KEY.pub")
EOF
multipass launch "$UBUNTU" --name "$SERVER_VM" --cpus 2 --memory 2G --disk 10G --cloud-init "$WORK/cloud-init.yaml" &
P1=$!
multipass launch "$UBUNTU" --name "$AGENT_VM" --cpus 2 --memory 2G --disk 10G --cloud-init "$WORK/cloud-init.yaml" &
P2=$!
wait "$P1" || fail "launching $SERVER_VM failed"
wait "$P2" || fail "launching $AGENT_VM failed"
vm_ip() { multipass info "$1" --format json | jq -r --arg n "$1" '.info[$n].ipv4[0]'; }
SERVER_IP=$(vm_ip "$SERVER_VM")
AGENT_IP=$(vm_ip "$AGENT_VM")
echo "$SERVER_VM: $SERVER_IP   $AGENT_VM: $AGENT_IP"

# ---------------------------------------------------------------------------
log "2/5 new-session.sh against $SERVER_VM"
"$SCRIPT_DIR/new-session.sh" "$SERVER_IP"

if [ "$RERUN" = "1" ]; then
  log "2b/5 new-session.sh again (bootstrap must be safe to re-run)"
  "$SCRIPT_DIR/new-session.sh" "$SERVER_IP"
fi

# ---------------------------------------------------------------------------
log "3/5 join-gpu-node.sh: $AGENT_VM joins $SERVER_VM"
"$SCRIPT_DIR/join-gpu-node.sh" "$SERVER_IP" "$AGENT_IP"

# ---------------------------------------------------------------------------
log "4/5 Checks through the laptop tunnel"
export KUBECONFIG="$KUBECONFIG_OUT"
kubectl get nodes -o wide
READY=$(kubectl get nodes -o json | jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length')
[ "$READY" = "2" ] || fail "expected 2 Ready nodes, got $READY"
kubectl get runtimeclass nvidia >/dev/null || fail "RuntimeClass 'nvidia' is missing"
# A pod on the agent resolving a name via CoreDNS on the server proves the pod
# network crosses nodes (flannel, UDP 8472); reading its logs proves the kubelet port (10250).
kubectl run vm-test-dns --image=busybox:1.36 --restart=Never \
  --overrides="{\"spec\":{\"nodeName\":\"$AGENT_VM\"}}" -- nslookup kubernetes.default.svc.cluster.local >/dev/null
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/vm-test-dns --timeout=180s \
  || fail "DNS lookup from a pod on $AGENT_VM failed (pod network between nodes)"
kubectl logs vm-test-dns >/dev/null || fail "cannot read logs from $AGENT_VM (kubelet port 10250)"
kubectl delete pod vm-test-dns >/dev/null
echo "2 nodes Ready, RuntimeClass nvidia present, cross-node DNS and kubelet logs work"

# ---------------------------------------------------------------------------
ELAPSED=$(( $(date +%s) - START ))
log "5/5 PASS in $((ELAPSED / 60))m$((ELAPSED % 60))s"
