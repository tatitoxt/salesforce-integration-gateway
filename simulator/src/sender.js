"use strict";

const { signatureHeader } = require("./signature");

/**
 * Signs and POSTs one event. `tamper` lets the demo show signature rejection.
 */
async function sendEvent({
  url,
  secret,
  event,
  timestamp = Math.floor(Date.now() / 1000),
  tamper = false,
  fetchImpl = globalThis.fetch,
  headers = {}
}) {
  const rawBody = typeof event === "string" ? event : JSON.stringify(event);
  const header = signatureHeader(secret, timestamp, rawBody);
  const response = await fetchImpl(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Stripe-Signature": header,
      ...headers
    },
    body: tamper ? `${rawBody} ` : rawBody
  });
  const text = await response.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    body = text;
  }
  return { status: response.status, body };
}

async function sendAll(events, options) {
  const results = [];
  for (const event of events) {
    const result = await sendEvent({ ...options, event });
    results.push({
      eventId: typeof event === "string" ? null : event.id,
      ...result
    });
  }
  return results;
}

module.exports = { sendEvent, sendAll };
