# tinyinfer

A Kubernetes-native LLM serving platform in Go: an OpenAI-compatible streaming
gateway plus an operator that deploys, routes, rate-limits, meters and
autoscales vLLM replicas on k3s.

Built on a local k3d cluster that mirrors the GPU cluster (CPU vLLM, fake
`nvidia.com/gpu`), then measured on E2E Cloud NVIDIA GPUs. Every number in
`bench/results/` comes from a GPU.

> Work in progress.

## Layout

| Path | What |
|---|---|
| `cmd/gateway` | Data plane: OpenAI-compatible streaming proxy |
| `cmd/loadgen` | Benchmark client: TTFT, ITL, throughput, cost per million tokens |
| `operator/` | Kubebuilder project: `InferenceService` CRD, controller, autoscaler |
| `internal/` | auth, ratelimit, metering, router, discovery, telemetry |
| `internal/teststub` | Small `httptest` OpenAI stub for unit tests and CI (no GPU) |
| `scripts/` | `local-up.sh` (k3d), GPU node bootstrap, session + tunnel, joining a second node, VM tests |
| `deploy/helm/tinyinfer` | Helm chart: gateway, vLLM model servers, Redis, Postgres (CRD + operator from phase 4) |
| `deploy/helm/tinyinfer` values | `values-local.yaml` (CPU vLLM), `values-e2e.yaml` (CUDA vLLM) |
| `deploy/manual` | Hand-written vLLM Deployments (week 1 on k3d, C0 on E2E) |
| `deploy/local` | k3d config, fake `nvidia.com/gpu` patch, RuntimeClass `nvidia` → runc |
| `deploy/gpu` | E2E: device-plugin time-slicing config, RuntimeClass `nvidia` |
| `deploy/bench` | loadgen Job and results PVC |
| `deploy/samples` | Example `InferenceService` objects |
| `deploy/dashboards` | Grafana dashboards |
| `bench/scenarios` | Load scenarios: sweep, ramp, burst, shared-prefix, multi-turn, noisy-neighbour |
| `bench/campaign` | One script per cloud run (C0–C8), dry-run on k3d first |
| `bench/results` | **E2E only**: raw JSON + plots, tagged with commit, GPU, model, vLLM version |
| `docs/` | Design doc, inference primer, local dev + parity table, GPU setup, ADRs |

## Development

```sh
make build                    # builds bin/gateway, bin/loadgen
make test                     # unit tests against internal/teststub, no GPU needed
make local-up / local-down    # k3d mirror of the GPU cluster
make deploy [ENV=local|e2e]   # ko-built images + Helm chart
make bench SCENARIO=<name>    # loadgen Job; ENV=local -> bench/local-runs/, ENV=e2e -> bench/results/
```

Local cluster (weeks 1–10): see [docs/local-dev.md](docs/local-dev.md).
GPU node for the measurement campaign (weeks 11–13): see [docs/gpu-setup.md](docs/gpu-setup.md).
