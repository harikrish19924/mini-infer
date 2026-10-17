# Local development (k3d mirror)

The laptop cluster mirrors the E2E GPU cluster: same k3s, chart, operator and
vLLM, with vLLM's CPU build and fake `nvidia.com/gpu`. It is for correctness
only. **No number measured here goes into `bench/results/`.**

## Pinned versions

| Thing | Local | E2E |
|---|---|---|
| vLLM image | `vllm/vllm-openai-cpu:v0.31.0` | `vllm/vllm-openai:v0.31.0` |
| k3s | v1.35.5+k3s1 (k3d 5.9.0) | v1.35.5+k3s1 |
| Docker VM | 10 CPUs / 16 GiB (Docker Desktop 4.46) | — |
| kube-prometheus-stack | 92.3.0 | |

## Cold start (local, Qwen 2.5 0.5B)

| Stage | Time |
|---|---|
| Image pull | |
| Weights download | |
| Weights load | |
| Ready on `/health` | |

## Parity checklist

CPU column filled in week 1; CUDA column filled in C0.

| Item | CPU vLLM | CUDA vLLM |
|---|---|---|
| SSE chunk format, final usage chunk with `stream_options.include_usage` | | |
| `vllm:num_requests_running`, `vllm:num_requests_waiting`, `vllm:kv_cache_usage_perc` | | |
| `vllm:prefix_cache_queries` / `vllm:prefix_cache_hits` exist and move on repeated prompts | | |
| `/tokenize` endpoint | | |
| `/health` behaviour; aborting a stream drops `num_requests_running` | | |

## Gaps and teststub fallbacks

<!-- Anything the CPU build lacks, and what covers it locally. -->
