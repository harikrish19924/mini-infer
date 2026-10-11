# GPU setup on E2E

How tinyinfer gets a working GPU Kubernetes cluster: an E2E Cloud L4 node running
k3s, with the GPU shared between pods by time-slicing, and vLLM serving a model.
The node is **disposable**: it is created at the start of a session and deleted at
the end, and `scripts/new-session.sh` rebuilds everything in about 15–20 minutes.

## The stack

Each layer depends on the one below it, which is why the setup order matters.

```
  Laptop ── kubectl / helm / curl ──┐  (SSH tunnel, port 6443)
                                    ▼
 ┌────────────────────── E2E GPU node (Ubuntu VM) ─────────────────────┐
 │  vLLM pod                         workload                          │
 │  RuntimeClass + device plugin     Kubernetes can schedule the GPU   │
 │  k3s (Kubernetes + containerd)    container orchestration           │
 │  NVIDIA container toolkit         containers can see the GPU        │
 │  NVIDIA driver (nvidia-smi)       Linux can see the GPU             │
 │  NVIDIA L4, 24 GB                 hardware                          │
 └─────────────────────────────────────────────────────────────────────┘
```

## Files

| File | Runs on | Purpose |
| --- | --- | --- |
| `scripts/install-dev-tools.sh` | laptop, once | Go, kubectl, Helm, kubebuilder, ko, golangci-lint, SSH key |
| `scripts/new-session.sh` | laptop, every session | Copies + runs the bootstrap on a fresh node, fetches kubeconfig, opens the tunnel |
| `scripts/bootstrap-gpu-node.sh` | node (copied by `new-session.sh`) | Driver check, toolkit, k3s, device plugin, smoke tests, optional vLLM |
| `deploy/gpu/time-slicing.yaml` | Helm value file | Advertises 1 GPU as 4 schedulable slots |
| `deploy/samples/vllm-qwen.yaml` | `kubectl apply` | vLLM serving Qwen2.5-1.5B-Instruct |

## One-time setup

1. **Laptop tools:** `bash scripts/install-dev-tools.sh`. Open a new terminal afterwards.
2. **E2E account:** sign up, verify OTP, complete the profile (Individual + PAN),
   finish customer validation (Aadhaar via DigiLocker, or ID + selfie), add credits.
3. **SSH key:** `install-dev-tools.sh` creates `~/.ssh/e2e_gpu`. Paste
   `~/.ssh/e2e_gpu.pub` into MyAccount → SSH Keys.
4. **Security group:** one inbound rule, **TCP 22 from your public IP only**
   (`<your-ip>/32`), outbound allow-all. Never open 6443 to the internet.

Use **MyAccount** (Compute → Nodes), not TIR. TIR's managed model endpoints do the
job this project builds, so they are only useful later as a benchmark comparison.

## Every session

```bash
# 1. MyAccount → Compute → Nodes → Create → GPU tab → L4 (≥100 GB disk), Ubuntu,
#    on-demand hourly, your SSH key, your security group, password login off.

# 2. Laptop, from the repo root:
./scripts/new-session.sh <node-public-ip> --with-vllm      # or: make session IP=<ip>

# 3. Work. In every new laptop terminal:
export KUBECONFIG=~/.kube/tinyinfer.yaml
kubectl get pods -A

# 4. Done for the day: copy results into the repo, commit, then
./scripts/new-session.sh stop                              # or: make stop
#    and DELETE the node in MyAccount. Check the billing log the next day.
```

Pin vLLM before benchmarking: `VLLM_TAG=<release-tag> ./scripts/new-session.sh <ip> --with-vllm`.

## What the bootstrap does, and why

### 1. NVIDIA driver
The driver lets Linux operate the GPU; `nvidia-smi` printing the L4 proves it works.
E2E GPU images initialise the driver on first boot, so the script waits up to 5
minutes. CUDA libraries come inside the vLLM container; the host only needs the driver.

### 2. NVIDIA container toolkit
Containers are isolated and normally cannot see `/dev/nvidia*` or the host's driver
libraries. The toolkit installs `nvidia-container-runtime`, a wrapper around `runc`
that injects the GPU devices and matching driver libraries when a container starts.

### 3. k3s
A complete Kubernetes distribution in one binary, with containerd built in. On
start-up k3s looks for `nvidia-container-runtime` and, if found, registers a
containerd runtime named `nvidia`. **The toolkit must be installed first**; if not,
`systemctl restart k3s` makes it re-detect. `--write-kubeconfig-mode 644` makes
`/etc/rancher/k3s/k3s.yaml` readable, and the script exports `KUBECONFIG` in
root's `.bashrc` so `helm` can find the cluster.

Check: `grep -i nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml`.

### 4. RuntimeClass `nvidia`
Tells Kubernetes that pods with `runtimeClassName: nvidia` start through the
`nvidia` containerd runtime. k3s creates RuntimeClasses for every runtime it knows
(`crun`, several WebAssembly runtimes, `nvidia-experimental`, ...); only `nvidia`
matters here. Its presence alone does not prove the runtime is installed: check
containerd's config as above.

### 5. NVIDIA device plugin, time-sliced
Kubernetes tracks CPU and memory by itself, not GPUs. The device plugin (a
DaemonSet) discovers the GPU and advertises it as the resource `nvidia.com/gpu`;
pods requesting `nvidia.com/gpu: 1` are then scheduled onto it.

- **Node label:** the chart only schedules on nodes labelled
  `nvidia.com/gpu.present=true`. That label normally comes from Node Feature
  Discovery, which we don't run, so the script adds it.
- **Time-slicing** (`deploy/gpu/time-slicing.yaml`): advertises the one L4 as 4
  slots. Compute is shared; memory is not, hence `--gpu-memory-utilization` on
  every vLLM pod. The L4 has no MIG (hardware partitioning with memory isolation);
  A100/H100 do.

Check: `kubectl describe node | grep 'nvidia.com/gpu:'` → `4` under Capacity and Allocatable.

### 6. GPU smoke test
A one-off pod (`nvidia/cuda` base image, `runtimeClassName: nvidia`, one GPU slot)
runs `nvidia-smi`. If its log shows the L4, the whole chain works:
pod → RuntimeClass → toolkit → driver → GPU.

### 7. vLLM (with `--with-vllm`)
Applies the equivalent of `deploy/samples/vllm-qwen.yaml`, waits for the rollout
(first time: image pull + weight download, several minutes) and sends a test chat
request. The YAML comments explain every field; the key ones:

| Setting | Why |
| --- | --- |
| `runtimeClassName: nvidia` + `nvidia.com/gpu: 1` | Get the GPU injected and reserve one slot |
| `--gpu-memory-utilization 0.4` | vLLM pre-allocates this share of GPU memory; leaves room for a 2nd replica |
| `--max-model-len 4096` | Smaller context → smaller KV cache per request → more concurrent requests |
| `--enable-prefix-caching` | Reuse KV blocks for shared prefixes (Phase 6) |
| `/dev/shm` memory volume | Default 64 MB shared memory crashes vLLM/PyTorch |
| `hf-cache` PVC | Weights survive pod restarts (not node deletion) |
| `startupProbe` (15 min budget) | Stops Kubernetes from killing the pod while the model loads |

Manual test:

```bash
kubectl port-forward svc/vllm 8000:8000
curl localhost:8000/v1/models
curl localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"qwen-1.5b","messages":[{"role":"user","content":"Say hi"}],"max_tokens":50}'
curl -N localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"qwen-1.5b","messages":[{"role":"user","content":"Count to 20"}],"stream":true}'
curl -s localhost:8000/metrics | grep -E 'vllm:(num_requests|kv_cache_usage)'
```

`kubectl logs deploy/vllm` shows how much KV cache vLLM allocated at start-up;
compare it with the hand calculation in `docs/inference-primer.md`.

## Laptop ↔ cluster

- `new-session.sh` copies `/etc/rancher/k3s/k3s.yaml` to `~/.kube/tinyinfer.yaml`.
  It points at `https://127.0.0.1:6443`.
- The tunnel `ssh -L 6443:127.0.0.1:6443 root@<node>` makes laptop port 6443 forward
  to the node's API server, so that kubeconfig works unchanged and 6443 never opens
  to the internet. `new-session.sh stop` closes it.
- **Never commit the kubeconfig**: it holds cluster-admin credentials.
- Images: `KO_DOCKER_REPO=ghcr.io/<github-user>/tinyinfer ko build ./cmd/gateway`
  builds and pushes without a Dockerfile. Make the GHCR package public, or give the
  cluster an image pull secret.

## Verification checklist

- [ ] `nvidia-smi` on the node shows the L4
- [ ] containerd config contains the `nvidia` runtime
- [ ] `kubectl -n nvidia-device-plugin get pods` → `2/2 Running`
- [ ] `kubectl describe node | grep 'nvidia.com/gpu:'` → `4`, twice
- [ ] `gpu-smoke` pod logs show the L4
- [ ] vLLM answers streamed and non-streamed requests
- [ ] `kubectl get nodes` works from the laptop
- [ ] A fresh node rebuilds from `new-session.sh` in under 20 minutes

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| GPU tab shows "No GPU Operating system available" | GPUs are only offered in some locations, or the account isn't fully enabled | Switch location (top bar) to Delhi or Mumbai; finish KYC; add credits; email cloud-platform@e2enetworks.com with your CRN |
| `nvidia-smi` fails | Driver not initialised or missing | Wait a few minutes after first boot; else `ubuntu-drivers install` and reboot |
| `Command 'helm' not found` | Helm not installed | `curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` |
| `Kubernetes cluster unreachable ... localhost:8080` | `KUBECONFIG` not set (or dropped by `sudo`) | `export KUBECONFIG=/etc/rancher/k3s/k3s.yaml`; use `sudo -i`, not `sudo helm` |
| `connection refused` on 6443 | k3s not running | `systemctl status k3s`, `systemctl restart k3s` |
| containerd config has no `nvidia` | k3s installed before the toolkit | `systemctl restart k3s` |
| No device-plugin pods (DaemonSet `DESIRED 0`) | Node lacks the GPU label | `kubectl label nodes --all nvidia.com/gpu.present=true` |
| Device-plugin pod stuck in `Init` for minutes | Image pull or config problem | `kubectl -n nvidia-device-plugin describe pod -l app.kubernetes.io/name=nvidia-device-plugin` |
| `nvidia.com/gpu` missing or 0 | Plugin not running or can't see the GPU | `kubectl -n nvidia-device-plugin logs -l app.kubernetes.io/name=nvidia-device-plugin --all-containers` |
| vLLM pod `Pending` | No free GPU slot | `kubectl describe pod -l app=vllm`; check the slot count, delete idle GPU pods |
| vLLM `CrashLoopBackOff`, CUDA out of memory | Memory shares exceed 1.0 across pods | Lower `--gpu-memory-utilization` or `--max-model-len` |
| SSH `Connection timed out` | Security group / home IP changed | Update the TCP 22 rule to your current IP |
| SSH `REMOTE HOST IDENTIFICATION HAS CHANGED` | New node reused an old IP | `ssh-keygen -R <ip>` (`new-session.sh` does this) |

## Cost and billing rules

- L4 on-demand: ₹49/hr + 18% GST (E2E price list, Oct 2026). Billed hourly.
- **Delete the node after every session.** E2E describes a powered-off node as
  "shut down but still allocated"; confirm in the billing log whether that is
  charged before relying on power-off.
- Nothing worth keeping lives only on the node: code is in git, results are copied
  back and committed, weights and images re-download.
- Avoid saved images (charged for full size) and leftover reserved IPs or volumes.
