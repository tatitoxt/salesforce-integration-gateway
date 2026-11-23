"use strict";

const http = require("node:http");
const { verifySignature } = require("./signature");

const MAX_BODY_BYTES = 65536;

/**
 * Local stand-in for /services/apexrest/payments/webhook. It mirrors the
 * synchronous Apex contract (fail-closed secret, signature, idempotency,
 * status codes) so the simulator can be exercised without a Salesforce org.
 * It does not implement matching or async processing.
 */
function createMockReceiver({
  secret,
  toleranceSeconds = 300,
  now = () => Date.now()
} = {}) {
  const events = new Map();

  function handle(rawBody, header) {
    if (!secret) {
      return [503, { status: "rejected", error: "gateway_not_configured" }];
    }
    if (rawBody.length === 0) {
      return [400, { status: "rejected", error: "empty_body" }];
    }
    const signature = verifySignature({
      header,
      rawBody,
      secret,
      toleranceSeconds,
      nowSeconds: Math.floor(now() / 1000)
    });
    if (!signature.valid) {
      return [401, { status: "rejected", error: signature.reason }];
    }
    if (rawBody.length > MAX_BODY_BYTES) {
      return [413, { status: "rejected", error: "payload_too_large" }];
    }
    let event;
    try {
      event = JSON.parse(rawBody.toString("utf8"));
    } catch {
      return [400, { status: "rejected", error: "invalid_json" }];
    }
    if (!event || typeof event !== "object" || Array.isArray(event)) {
      return [400, { status: "rejected", error: "invalid_json" }];
    }
    if (!event.id) {
      return [400, { status: "rejected", error: "missing_event_id" }];
    }
    if (!event.type) {
      return [400, { status: "rejected", error: "missing_event_type" }];
    }
    const key = String(event.id).toLowerCase();
    if (events.has(key)) {
      return [
        200,
        {
          status: "duplicate",
          eventId: event.id,
          recordId: events.get(key).recordId
        }
      ];
    }
    const recordId = `mock-${events.size + 1}`;
    events.set(key, { recordId, type: event.type, event });
    return [202, { status: "accepted", eventId: event.id, recordId }];
  }

  const server = http.createServer((request, response) => {
    if (
      request.method !== "POST" ||
      request.url !== "/services/apexrest/payments/webhook"
    ) {
      response.writeHead(404, { "Content-Type": "application/json" });
      response.end(JSON.stringify({ error: "not_found" }));
      return;
    }
    const chunks = [];
    request.on("data", (chunk) => chunks.push(chunk));
    request.on("end", () => {
      const [status, body] = handle(
        Buffer.concat(chunks),
        request.headers["stripe-signature"]
      );
      response.writeHead(status, { "Content-Type": "application/json" });
      response.end(JSON.stringify(body));
    });
  });

  return { server, events, handle };
}

module.exports = { createMockReceiver, MAX_BODY_BYTES };
