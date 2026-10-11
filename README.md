# tinyinfer

A Kubernetes-native LLM serving platform in Go, built and benchmarked on real
NVIDIA GPUs: an OpenAI-compatible streaming gateway plus an operator that
deploys, routes, rate-limits, meters and autoscales vLLM replicas on k3s.

> Work in progress.

## Layout

| Path | What |
|---|---|
| `cmd/gateway` | Data plane: OpenAI-compatible streaming proxy |
| `cmd/loadgen` | Benchmark client: TTFT, ITL, throughput, cost per million tokens |
| `operator/` | Kubebuilder project: `InferenceService` CRD, controller, autoscaler |
| `internal/` | auth, ratelimit, metering, router, discovery, telemetry |
| `internal/teststub` | Small `httptest` OpenAI stub for unit tests and CI (no GPU) |
| `scripts/` | GPU node bootstrap, joining a second node, SSH tunnel |
| `deploy/helm/tinyinfer` | Helm chart: CRD, operator, gateway, Redis, Postgres |
| `deploy/gpu` | Device-plugin time-slicing config, RuntimeClass |
| `deploy/samples` | Example `InferenceService` objects |
| `deploy/dashboards` | Grafana dashboards |
| `bench/` | Load scenarios and committed results (tagged with commit, GPU, vLLM version) |
| `docs/` | Design doc, inference primer, GPU setup, ADRs |

## Development

```sh
make build   # builds bin/gateway, bin/loadgen
make test    # unit tests against internal/teststub, no GPU needed
```

Cluster setup on a GPU node: see [docs/gpu-setup.md](docs/gpu-setup.md).
