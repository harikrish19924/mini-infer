# tinyinfer

A Kubernetes-native LLM serving platform in Go: an OpenAI-compatible streaming
gateway plus an operator that deploys, routes, rate-limits, meters and autoscales
model replicas (vLLM, or a simulated `fakemodel` for laptop development).

> Work in progress.

## Layout

| Path | What |
|---|---|
| `cmd/gateway` | Data plane: OpenAI-compatible proxy |
| `cmd/fakemodel` | Simulated model server for development without a GPU |
| `cmd/loadgen` | Benchmark client (TTFT, ITL, throughput) |
| `operator/` | Kubebuilder project: `InferenceService` CRD, controller, autoscaler |
| `internal/` | auth, ratelimit, metering, router, discovery, telemetry |
| `deploy/` | Helm chart, k3d config, Grafana dashboards |
| `bench/` | Load scenarios and committed results |
| `docs/` | Design doc, inference primer, ADRs |

## Development

```sh
make build   # builds bin/gateway, bin/fakemodel, bin/loadgen
make test
make dev     # local k3d cluster
```
