# Benchmarks

Measured with `simulator/bin/benchmark.js` — real Stripe-style signed events
POSTed over a real HTTP socket through the mock receiver's full contract:
HMAC-SHA256 verification, timestamp tolerance, 64 KB cap, JSON validation
and idempotent dedup by event id.

**How to reproduce**

```sh
node simulator/bin/benchmark.js --events 2000 --concurrency 10   # --json for raw output
```

**Results (2026-11-21, 2,000-event mixed workload: payments, refunds, disputes, invoice.paid)**

| Metric                    |                                   Value |
| ------------------------- | --------------------------------------: |
| Signed webhook throughput |                    **4,089 events/sec** |
| Per-event latency         |               1.43 ms p50 / 5.89 ms p99 |
| Accepted on first pass    |                    2,000 / 2,000 (100%) |
| Idempotent replay         | 2,000 / 2,000 deduped (100% dedup rate) |

**Reading the numbers**

- Each event is HMAC-signed, sent over HTTP, verified, validated and
  recorded — this is the same contract the Apex webhook enforces.
- The 100% dedup rate on a full replay is the at-least-once delivery
  guarantee: a provider retry never double-creates a payment record.
- Machine-dependent numbers; a reproducible baseline, not a marketing figure.
