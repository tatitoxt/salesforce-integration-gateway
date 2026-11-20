"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  paymentSucceeded,
  refundCreated,
  toMinorUnits,
  SCENARIOS,
  bulk
} = require("../../src/events");

test("payment events carry the fields the Apex parser reads", () => {
  const event = paymentSucceeded({
    invoiceNumber: "INV-1",
    amount: 125.5,
    currency: "USD",
    created: 10
  });
  assert.match(event.id, /^evt_sim_[0-9a-f]{24}$/);
  assert.equal(event.type, "payment_intent.succeeded");
  assert.equal(event.created, 10);
  assert.equal(event.livemode, false);
  assert.equal(event.data.object.amount, 12550);
  assert.equal(event.data.object.currency, "usd");
  assert.deepEqual(event.data.object.metadata, { invoice_number: "INV-1" });
  assert.deepEqual(paymentSucceeded({ amount: 1 }).data.object.metadata, {});
});

test("refund events reference the original payment", () => {
  const event = refundCreated({
    paymentId: "pi_1",
    amount: 5,
    currency: "eur"
  });
  assert.equal(event.type, "refund.created");
  assert.equal(event.data.object.payment_intent, "pi_1");
  assert.equal(event.data.object.amount, 500);
  assert.throws(() => refundCreated({ amount: 5 }), /paymentId/);
});

test("converts to minor units and validates amounts", () => {
  assert.equal(toMinorUnits("19.99", "usd"), 1999);
  assert.equal(toMinorUnits(1500, "JPY"), 1500);
  for (const code of ["ugx", "XOF", "PYG", "VUV"]) {
    assert.equal(toMinorUnits(1500, code), 1500, code);
  }
  assert.throws(() => toMinorUnits(-1, "usd"), /Invalid amount/);
  assert.throws(() => toMinorUnits("abc", "usd"), /Invalid amount/);
});

test("scenarios produce the documented event shapes", () => {
  assert.deepEqual(Object.keys(SCENARIOS).sort(), [
    "currency-mismatch",
    "duplicate",
    "full-payment",
    "partial-payments",
    "refund",
    "refund-before-payment",
    "unknown-invoice"
  ]);
  const [payment, refund] = SCENARIOS.refund();
  assert.equal(refund.data.object.payment_intent, payment.data.object.id);
  const [first, second] = SCENARIOS.duplicate();
  assert.equal(first.id, second.id);
  assert.equal(SCENARIOS["partial-payments"]().length, 2);
});

test("bulk generates unique events for sequential invoices", () => {
  const events = bulk({ count: 200 });
  assert.equal(events.length, 200);
  assert.equal(new Set(events.map((event) => event.id)).size, 200);
  assert.equal(
    events[199].data.object.metadata.invoice_number,
    "INV-BULK-0199"
  );
});
