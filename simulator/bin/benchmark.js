#!/usr/bin/env node
/**
 * Webhook pipeline benchmark: signs real events and POSTs them through the
 * mock receiver's full contract — HMAC verification, 64 KB cap, JSON
 * validation and idempotent dedup — over a real HTTP socket.
 *
 *   node simulator/bin/benchmark.js [--events 2000] [--concurrency 10] [--json]
 */
"use strict";

const { createMockReceiver } = require("../src/mockReceiver");
const { sendEvent } = require("../src/sender");
const events = require("../src/events");

const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : fallback;
};
const TOTAL = Number(arg("events", "2000"));
const CONCURRENCY = Number(arg("concurrency", "10"));
const JSON_OUT = process.argv.includes("--json");
const SECRET = "whsec_bench";

const percentile = (xs, p) => {
  const sorted = [...xs].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))];
};

async function main() {
  const { server, handle } = createMockReceiver({ secret: SECRET });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const url = `http://127.0.0.1:${server.address().port}/services/apexrest/payments/webhook`;

  // A mixed workload: payments, refunds, disputes and invoice.paid events.
  const builders = [
    (i) => events.paymentSucceeded({ invoiceNumber: `INV-BENCH-${i % 50}`, amount: 100 + (i % 900) }),
    (i) => events.refundCreated({ paymentId: `pi_${i}`, amount: 50 + (i % 400) }),
    (i) => events.disputeCreated({ paymentId: `pi_${i}`, amount: 200 + (i % 500) }),
    (i) => events.invoicePaid({ invoiceNumber: `INV-BENCH-${i % 50}`, amountPaid: 100 + (i % 900) }),
  ];
  const batch = Array.from({ length: TOTAL }, (_, i) => builders[i % builders.length](i));

  const latencies = [];
  let accepted = 0;
  const t0 = performance.now();
  for (let off = 0; off < batch.length; off += CONCURRENCY) {
    const results = await Promise.all(
      batch.slice(off, off + CONCURRENCY).map(async (event) => {
        const s = performance.now();
        const res = await sendEvent({ url, secret: SECRET, event });
        latencies.push(performance.now() - s);
        return res;
      })
    );
    accepted += results.filter((r) => r.status === 202).length;
  }
  const elapsed = performance.now() - t0;

  // Replay the whole batch: every event must dedup, not double-create.
  const replay0 = performance.now();
  let duplicates = 0;
  for (let off = 0; off < batch.length; off += CONCURRENCY) {
    const results = await Promise.all(
      batch.slice(off, off + CONCURRENCY).map((event) =>
        sendEvent({ url, secret: SECRET, event })
      )
    );
    duplicates += results.filter((r) => r.status === 200 && r.body.status === "duplicate").length;
  }
  const replayMs = performance.now() - replay0;

  server.close();
  const out = {
    events: TOTAL,
    concurrency: CONCURRENCY,
    accepted,
    events_per_sec: Math.round((TOTAL / elapsed) * 1000),
    latency_ms: {
      p50: +percentile(latencies, 0.5).toFixed(2),
      p99: +percentile(latencies, 0.99).toFixed(2),
    },
    replay: { duplicates, ms: Math.round(replayMs), dedup_rate: +(duplicates / TOTAL).toFixed(3) },
    recorded: handle ? undefined : undefined,
  };
  if (JSON_OUT) {
    console.log(JSON.stringify(out, null, 2));
  } else {
    console.log(`webhook pipeline: ${out.events_per_sec} events/sec ` +
      `(p50 ${out.latency_ms.p50} ms, p99 ${out.latency_ms.p99} ms), ` +
      `${accepted}/${TOTAL} accepted`);
    console.log(`idempotent replay: ${duplicates}/${TOTAL} deduped in ${Math.round(replayMs)} ms`);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
