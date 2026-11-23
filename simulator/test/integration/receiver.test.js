"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  createMockReceiver,
  MAX_BODY_BYTES
} = require("../../src/mockReceiver");
const { sendEvent, sendAll } = require("../../src/sender");
const { paymentSucceeded, SCENARIOS, bulk } = require("../../src/events");

const SECRET = "whsec_integration_fixture";

async function withReceiver(options, fn) {
  const receiver = createMockReceiver({ secret: SECRET, ...options });
  await new Promise((resolve) =>
    receiver.server.listen(0, "127.0.0.1", resolve)
  );
  const url = `http://127.0.0.1:${receiver.server.address().port}/services/apexrest/payments/webhook`;
  try {
    await fn({ url, receiver });
  } finally {
    await new Promise((resolve) => receiver.server.close(resolve));
  }
}

test("accepts a signed event over HTTP and stores it once", async () => {
  await withReceiver({}, async ({ url, receiver }) => {
    const event = paymentSucceeded({ invoiceNumber: "INV-1", amount: 10 });
    const first = await sendEvent({ url, secret: SECRET, event });
    const second = await sendEvent({ url, secret: SECRET, event });
    assert.equal(first.status, 202);
    assert.equal(first.body.status, "accepted");
    assert.equal(second.status, 200);
    assert.equal(second.body.status, "duplicate");
    assert.equal(second.body.recordId, first.body.recordId);
    assert.equal(receiver.events.size, 1);
  });
});

test("rejects tampered bodies, wrong secrets and stale timestamps", async () => {
  await withReceiver({}, async ({ url, receiver }) => {
    const event = paymentSucceeded({ invoiceNumber: "INV-1", amount: 10 });
    const tampered = await sendEvent({
      url,
      secret: SECRET,
      event,
      tamper: true
    });
    const wrongSecret = await sendEvent({ url, secret: "nope", event });
    const stale = await sendEvent({
      url,
      secret: SECRET,
      event,
      timestamp: Math.floor(Date.now() / 1000) - 3600
    });
    assert.deepEqual(
      [tampered.status, wrongSecret.status, stale.status],
      [401, 401, 401]
    );
    assert.equal(tampered.body.error, "signature_mismatch");
    assert.equal(stale.body.error, "stale_timestamp");
    assert.equal(receiver.events.size, 0);
  });
});

test("fails closed without a configured secret", async () => {
  await withReceiver({ secret: "" }, async ({ url }) => {
    const result = await sendEvent({
      url,
      secret: SECRET,
      event: paymentSucceeded({ amount: 1 })
    });
    assert.equal(result.status, 503);
    assert.equal(result.body.error, "gateway_not_configured");
  });
});

test("validates payload shape and size like the Apex endpoint", async () => {
  await withReceiver({}, async ({ url }) => {
    assert.equal(
      (await sendEvent({ url, secret: SECRET, event: "not json" })).body.error,
      "invalid_json"
    );
    assert.equal(
      (await sendEvent({ url, secret: SECRET, event: "[1]" })).body.error,
      "invalid_json"
    );
    assert.equal(
      (await sendEvent({ url, secret: SECRET, event: { type: "x" } })).body
        .error,
      "missing_event_id"
    );
    assert.equal(
      (await sendEvent({ url, secret: SECRET, event: { id: "evt" } })).body
        .error,
      "missing_event_type"
    );
    const big = { id: "evt_big", type: "x", pad: "x".repeat(MAX_BODY_BYTES) };
    assert.equal(
      (await sendEvent({ url, secret: SECRET, event: big })).status,
      413
    );
    const empty = await fetch(url, { method: "POST", body: "" });
    assert.equal(empty.status, 400);
    const notFound = await fetch(url.replace("webhook", "other"), {
      method: "POST"
    });
    assert.equal(notFound.status, 404);
  });
});

test("sends a scenario and a 200-event bulk batch", async () => {
  await withReceiver({}, async ({ url, receiver }) => {
    const duplicate = await sendAll(SCENARIOS.duplicate(), {
      url,
      secret: SECRET
    });
    assert.deepEqual(
      duplicate.map((result) => result.status),
      [202, 200]
    );
    const results = await sendAll(bulk({ count: 200 }), {
      url,
      secret: SECRET
    });
    assert.equal(results.filter((result) => result.status === 202).length, 200);
    assert.equal(receiver.events.size, 201);
  });
});
