"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  paymentSucceeded,
  refundCreated,
  disputeCreated,
  disputeClosed,
  invoicePaid,
  paymentFailed,
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

test("dispute events reference the original payment", () => {
  const event = disputeCreated({
    paymentId: "pi_1",
    amount: 25,
    reason: "duplicate"
  });
  assert.equal(event.type, "charge.dispute.created");
  assert.equal(event.data.object.object, "dispute");
  assert.equal(event.data.object.payment_intent, "pi_1");
  assert.equal(event.data.object.amount, 2500);
  assert.equal(event.data.object.reason, "duplicate");
  assert.throws(() => disputeCreated({ amount: 5 }), /paymentId/);
});

test("dispute.closed events carry the outcome status", () => {
  const event = disputeClosed({
    disputeId: "dp_x",
    paymentId: "pi_x",
    status: "lost",
    amount: 10
  });
  assert.equal(event.type, "charge.dispute.closed");
  assert.equal(event.data.object.id, "dp_x");
  assert.equal(event.data.object.status, "lost");
  assert.equal(event.data.object.payment_intent, "pi_x");
  assert.throws(() => disputeClosed({ amount: 5 }), /disputeId/);
});

test("dispute-won/lost scenarios close a recorded dispute", () => {
  for (const name of ["dispute-won", "dispute-lost"]) {
    const [paid, opened, closed] = SCENARIOS[name]();
    assert.equal(opened.data.object.id, closed.data.object.id);
    assert.equal(closed.data.object.payment_intent, paid.data.object.id);
  }
  assert.equal(SCENARIOS["dispute-won"]()[2].data.object.status, "won");
  assert.equal(SCENARIOS["dispute-lost"]()[2].data.object.status, "lost");
});

test("invoice.paid events carry number and amount_paid", () => {
  const event = invoicePaid({
    invoiceNumber: "INV-9",
    amountPaid: 99.5,
    currency: "eur"
  });
  assert.equal(event.type, "invoice.paid");
  assert.equal(event.data.object.object, "invoice");
  assert.equal(event.data.object.number, "INV-9");
  assert.equal(event.data.object.amount_paid, 9950);
  assert.equal(event.data.object.currency, "eur");
});

test("scenarios produce the documented event shapes", () => {
  assert.deepEqual(Object.keys(SCENARIOS).sort(), [
    "currency-mismatch",
    "dispute",
    "dispute-before-payment",
    "dispute-lost",
    "dispute-won",
    "duplicate",
    "full-payment",
    "invoice-paid-upstream",
    "partial-payments",
    "payment-declined",
    "payment-declined-unknown",
    "refund",
    "refund-before-payment",
    "unknown-invoice"
  ]);
  const [paid, disputed] = SCENARIOS.dispute();
  assert.equal(disputed.data.object.payment_intent, paid.data.object.id);
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

test("paymentFailed builds a declined intent with failure details", () => {
  const event = paymentFailed({
    invoiceNumber: "INV-1",
    amount: 150,
    declineCode: "insufficient_funds"
  });
  assert.equal(event.type, "payment_intent.payment_failed");
  const obj = event.data.object;
  assert.equal(obj.object, "payment_intent");
  assert.equal(obj.amount, 15000);
  assert.equal(obj.metadata.invoice_number, "INV-1");
  assert.equal(obj.last_payment_error.code, "insufficient_funds");
  const noInvoice = paymentFailed({ amount: 10 });
  assert.equal(noInvoice.data.object.metadata, undefined);
});

