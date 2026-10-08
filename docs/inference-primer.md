# Inference primer

Phase 0 deliverable, in my own words:

1. Prefill vs decode
2. KV cache (size formula, worked example for a 7B model)
3. Continuous batching and PagedAttention
4. Prefix caching
5. Serving metrics: TTFT, ITL/TPOT, end-to-end latency, tokens/s, goodput
6. Why a CPU-based autoscaler is wrong for an LLM server
