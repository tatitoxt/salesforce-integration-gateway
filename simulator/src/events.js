"use strict";

const crypto = require("node:crypto");

// Keep in sync with ZERO_DECIMAL_CURRENCIES in PaymentEventPayload.cls.
const ZERO_DECIMAL = new Set([
  "BIF",
  "CLP",
  "DJF",
  "GNF",
  "JPY",
  "KMF",
  "KRW",
  "MGA",
  "PYG",
  "RWF",
  "UGX",
  "VND",
  "VUV",
  "XAF",
  "XOF",
  "XPF"
]);

function toMinorUnits(amount, currency) {
  const value = Number(amount);
  if (!Number.isFinite(value) || value < 0) {
    throw new Error(`Invalid amount: ${amount}`);
  }
  return ZERO_DECIMAL.has(currency.toUpperCase())
    ? Math.round(value)
    : Math.round(value * 100);
}

function randomId(prefix) {
  return `${prefix}_${crypto.randomBytes(12).toString("hex")}`;
}

function envelope({ id, type, created, object }) {
  return {
    id,
    object: "event",
    type,
    created,
    livemode: false,
    data: { object }
  };
}

function paymentSucceeded({
  invoiceNumber,
  amount,
  currency = "usd",
  paymentId = randomId("pi_sim"),
  eventId = randomId("evt_sim"),
  customer = "cus_synthetic_demo",
  created = Math.floor(Date.now() / 1000)
}) {
  const metadata = invoiceNumber ? { invoice_number: invoiceNumber } : {};
  return envelope({
    id: eventId,
    type: "payment_intent.succeeded",
    created,
    object: {
      id: paymentId,
      object: "payment_intent",
      amount: toMinorUnits(amount, currency),
      currency: currency.toLowerCase(),
      customer,
      metadata
    }
  });
}

function refundCreated({
  paymentId,
  amount,
  currency = "usd",
  refundId = randomId("re_sim"),
  eventId = randomId("evt_sim"),
  created = Math.floor(Date.now() / 1000)
}) {
  if (!paymentId) {
    throw new Error("refund requires paymentId");
  }
  return envelope({
    id: eventId,
    type: "refund.created",
    created,
    object: {
      id: refundId,
      object: "refund",
      amount: toMinorUnits(amount, currency),
      currency: currency.toLowerCase(),
      payment_intent: paymentId
    }
  });
}

function disputeCreated({
  paymentId,
  amount,
  currency = "usd",
  reason = "fraudulent",
  disputeId = randomId("dp_sim"),
  eventId = randomId("evt_sim"),
  created = Math.floor(Date.now() / 1000)
}) {
  if (!paymentId) {
    throw new Error("dispute requires paymentId");
  }
  return envelope({
    id: eventId,
    type: "charge.dispute.created",
    created,
    object: {
      id: disputeId,
      object: "dispute",
      amount: toMinorUnits(amount, currency),
      currency: currency.toLowerCase(),
      payment_intent: paymentId,
      reason
    }
  });
}

function invoicePaid({
  invoiceNumber,
  amountPaid,
  currency = "usd",
  invoiceId = randomId("in_sim"),
  eventId = randomId("evt_sim"),
  customer = "cus_synthetic_demo",
  created = Math.floor(Date.now() / 1000)
}) {
  return envelope({
    id: eventId,
    type: "invoice.paid",
    created,
    object: {
      id: invoiceId,
      object: "invoice",
      number: invoiceNumber,
      amount_paid: toMinorUnits(amountPaid, currency),
      currency: currency.toLowerCase(),
      customer
    }
  });
}

/**
 * Named, synthetic scenarios matching the demo invoices in scripts/demo-data.apex.
 * Each returns an ordered list of events.
 */
const SCENARIOS = {
  "full-payment": () => [
    paymentSucceeded({ invoiceNumber: "INV-DEMO-0001", amount: 1200 })
  ],
  "partial-payments": () => [
    paymentSucceeded({ invoiceNumber: "INV-DEMO-0002", amount: 300 }),
    paymentSucceeded({ invoiceNumber: "INV-DEMO-0002", amount: 200 })
  ],
  refund: () => {
    const payment = paymentSucceeded({
      invoiceNumber: "INV-DEMO-0003",
      amount: 450
    });
    return [
      payment,
      refundCreated({ paymentId: payment.data.object.id, amount: 50 })
    ];
  },
  "unknown-invoice": () => [
    paymentSucceeded({ invoiceNumber: "INV-DOES-NOT-EXIST", amount: 99 })
  ],
  "currency-mismatch": () => [
    paymentSucceeded({
      invoiceNumber: "INV-DEMO-0004",
      amount: 80,
      currency: "eur"
    })
  ],
  "refund-before-payment": () => [
    refundCreated({ paymentId: randomId("pi_sim_missing"), amount: 25 })
  ],
  dispute: () => {
    const payment = paymentSucceeded({
      invoiceNumber: "INV-DEMO-0001",
      amount: 1200
    });
    return [
      payment,
      disputeCreated({ paymentId: payment.data.object.id, amount: 1200 })
    ];
  },
  "dispute-before-payment": () => [
    disputeCreated({ paymentId: randomId("pi_sim_missing"), amount: 25 })
  ],
  "invoice-paid-upstream": () => [
    invoicePaid({ invoiceNumber: "INV-DEMO-0001", amountPaid: 1200 })
  ],
  duplicate: () => {
    const event = paymentSucceeded({
      invoiceNumber: "INV-DEMO-0005",
      amount: 75
    });
    return [event, event];
  }
};

function bulk({
  count,
  invoicePrefix = "INV-BULK-",
  amount = 10,
  currency = "usd"
}) {
  return Array.from({ length: count }, (_, index) =>
    paymentSucceeded({
      invoiceNumber: `${invoicePrefix}${String(index).padStart(4, "0")}`,
      amount,
      currency
    })
  );
}

module.exports = {
  paymentSucceeded,
  refundCreated,
  disputeCreated,
  invoicePaid,
  toMinorUnits,
  SCENARIOS,
  bulk
};
