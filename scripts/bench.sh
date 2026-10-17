#!/usr/bin/env bash
# bench.sh — run one loadgen scenario as a Job inside the cluster and copy its
# results to the laptop. Called by `make bench SCENARIO=<name> [ENV=local|e2e]`.
#
# Usage:
#   scripts/bench.sh <local|e2e> <scenario>
#
# Where results land (rule 1: laptop numbers never enter bench/results/):
#   ENV=local -> bench/local-runs/<run-id>/   (git-ignored)
#   ENV=e2e   -> bench/results/<run-id>/
#
# What it expects from files you write:
#   bench/scenarios/<scenario>.*      exactly one file; loadgen's input for this run
#   deploy/bench/*.yaml               a Job named "loadgen" (image: ko://github.com/harikrish19924/mini-infer/cmd/loadgen)
#                                     and a PVC named "bench-results"
# The Job should mount ConfigMap "loadgen-run", which this script fills with:
#   scenario   the scenario file's contents
#   RUN_ID, SCENARIO, COMMIT, ENV     (e.g. via envFrom)
# and write everything for the run under /results/$RUN_ID/ on the PVC.
#
# Optional environment variables:
#   KO_DOCKER_REPO        where ko pushes (default: localhost:5111 local, ghcr.io/harikrish19924/mini-infer e2e)
#   BENCH_TIMEOUT=3600    seconds to wait for the Job
#   ALLOW_DIRTY=1         allow an e2e run from uncommitted code

set -euo pipefail

ENV="${1:-}"; SCENARIO="${2:-}"
[ -n "$ENV" ] && [ -n "$SCENARIO" ] || { sed -n '2,27p' "$0"; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_TIMEOUT="${BENCH_TIMEOUT:-3600}"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

case "$ENV" in
local)
  KC=(kubectl --context k3d-tinyinfer)
  KO_DOCKER_REPO="${KO_DOCKER_REPO:-localhost:5111}"
  PLATFORM=linux/arm64
  DEST_ROOT="$ROOT/bench/local-runs"
  ;;
e2e)
  KC=(kubectl --kubeconfig "$HOME/.kube/tinyinfer.yaml")
  KO_DOCKER_REPO="${KO_DOCKER_REPO:-ghcr.io/harikrish19924/mini-infer}"
  PLATFORM=linux/amd64
  DEST_ROOT="$ROOT/bench/results"
  ;;
*) fail "ENV must be local or e2e, got '$ENV'" ;;
esac
export KO_DOCKER_REPO
kc() { "${KC[@]}" "$@"; }

command -v ko >/dev/null || fail "ko not found (brew install ko)"
SCENARIO_FILES=("$ROOT"/bench/scenarios/"$SCENARIO".*)
[ -f "${SCENARIO_FILES[0]}" ] || fail "no scenario file bench/scenarios/$SCENARIO.*"
[ "${#SCENARIO_FILES[@]}" -eq 1 ] || fail "more than one bench/scenarios/$SCENARIO.* file"
ls "$ROOT"/deploy/bench/*.yaml >/dev/null 2>&1 || fail "no manifests in deploy/bench/ yet (loadgen Job + bench-results PVC)"
kc get nodes >/dev/null 2>&1 || fail "cannot reach the $ENV cluster"

COMMIT=$(git -C "$ROOT" rev-parse --short HEAD)
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
  [ "$ENV" = "e2e" ] && [ "${ALLOW_DIRTY:-0}" != "1" ] \
    && fail "uncommitted changes: e2e results must come from a commit (ALLOW_DIRTY=1 to override)"
  COMMIT="$COMMIT-dirty"
fi
RUN_ID="$SCENARIO-$(date -u +%Y%m%d-%H%M%S)"
DEST="$DEST_ROOT/$RUN_ID"

# ---------------------------------------------------------------------------
log "1/4 Run $RUN_ID ($ENV, commit $COMMIT)"
kc create configmap loadgen-run \
  --from-file=scenario="${SCENARIO_FILES[0]}" \
  --from-literal=RUN_ID="$RUN_ID" \
  --from-literal=SCENARIO="$SCENARIO" \
  --from-literal=COMMIT="$COMMIT" \
  --from-literal=ENV="$ENV" \
  --dry-run=client -o yaml | kc apply -f -
# A Job's pod template is immutable, so replace the previous run's Job.
kc delete job loadgen --ignore-not-found --wait=true

# ---------------------------------------------------------------------------
log "2/4 Building loadgen with ko ($KO_DOCKER_REPO, $PLATFORM) and starting the Job"
(cd "$ROOT" && ko resolve --base-import-paths --platform="$PLATFORM" -f deploy/bench/) | kc apply -f -

# ---------------------------------------------------------------------------
log "3/4 Waiting for the Job (up to ${BENCH_TIMEOUT}s); follow with: ${KC[*]} logs -f job/loadgen"
STATUS=timeout
for _ in $(seq 1 $(( BENCH_TIMEOUT / 5 ))); do
  if [ "$(kc get job loadgen -o jsonpath='{.status.succeeded}')" = "1" ]; then STATUS=succeeded; break; fi
  if [ -n "$(kc get job loadgen -o jsonpath='{.status.failed}')" ] \
     && [ "$(kc get job loadgen -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}')" = "True" ]; then
    STATUS=failed; break
  fi
  sleep 5
done
echo "Job $STATUS"

# ---------------------------------------------------------------------------
log "4/4 Copying results to ${DEST#"$ROOT"/}"
mkdir -p "$DEST"
kc logs job/loadgen > "$DEST/loadgen.log" 2>&1 || true
# The Job's pod has exited, so a short-lived pod mounts the PVC for kubectl cp.
kc delete pod bench-copy --ignore-not-found --wait=true >/dev/null
kc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: bench-copy
spec:
  restartPolicy: Never
  containers:
  - name: copy
    image: busybox:1.36
    command: ["sleep", "600"]
    volumeMounts:
    - { name: results, mountPath: /results }
  volumes:
  - name: results
    persistentVolumeClaim: { claimName: bench-results }
EOF
kc wait --for=condition=Ready pod/bench-copy --timeout=120s >/dev/null \
  || fail "copy pod did not start (is the PVC named bench-results?)"
if kc exec bench-copy -- test -d "/results/$RUN_ID"; then
  kc cp "bench-copy:/results/$RUN_ID" "$DEST"
else
  echo "no /results/$RUN_ID on the PVC (loadgen wrote nothing for this run)"
fi
kc delete pod bench-copy --wait=false >/dev/null

ls -la "$DEST"
[ "$STATUS" = "succeeded" ] || fail "loadgen Job $STATUS; see $DEST/loadgen.log"
printf '\n\033[32mDone:\033[0m %s\n' "${DEST#"$ROOT"/}"
