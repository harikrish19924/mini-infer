# Inference primer

Phase 0 deliverable, in my own words, checked against a live vLLM on the L4:

1. Prefill vs decode (observed: long prompt vs long generation, TTFT vs ITL)
2. KV cache: per-token size by hand for Qwen 2.5 1.5B and an 8B model,
   compared with the KV cache capacity in vLLM's startup log
3. Continuous batching and PagedAttention: why throughput rises with concurrency
   until the KV cache fills
4. Prefix caching: vLLM's block cache of token IDs
5. Serving metrics: TTFT, ITL, end-to-end latency, tokens/s, p50/p99, goodput,
   cost per million tokens
6. Why CPU-based autoscaling is wrong for vLLM
