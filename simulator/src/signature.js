"use strict";

const crypto = require("node:crypto");

/** HMAC-SHA256 over "<timestamp>.<raw body>", hex encoded (Stripe-style v1). */
function computeSignature(secret, timestamp, rawBody) {
  if (!secret) {
    throw new Error("A signing secret is required");
  }
  return crypto
    .createHmac("sha256", secret)
    .update(Buffer.concat([Buffer.from(`${timestamp}.`), Buffer.from(rawBody)]))
    .digest("hex");
}

function signatureHeader(secret, timestamp, rawBody) {
  return `t=${timestamp},v1=${computeSignature(secret, timestamp, rawBody)}`;
}

function parseSignatureHeader(header) {
  const result = { timestamp: null, signatures: [] };
  if (!header) {
    return result;
  }
  for (const part of header.split(",")) {
    const separator = part.indexOf("=");
    if (separator <= 0) {
      continue;
    }
    const key = part.slice(0, separator).trim();
    const value = part.slice(separator + 1).trim();
    if (key === "t" && /^\d+$/.test(value)) {
      result.timestamp = Number(value);
    } else if (key === "v1") {
      result.signatures.push(value.toLowerCase());
    }
  }
  return result;
}

/** Mirrors WebhookSignatureVerifier.cls so the mock receiver behaves like the org. */
function verifySignature({
  header,
  rawBody,
  secret,
  nowSeconds,
  toleranceSeconds = 300
}) {
  if (!header || !header.trim()) {
    return { valid: false, reason: "missing_signature" };
  }
  const { timestamp, signatures } = parseSignatureHeader(header);
  if (timestamp === null || signatures.length === 0) {
    return { valid: false, reason: "malformed_signature" };
  }
  if (Math.abs(nowSeconds - timestamp) > toleranceSeconds) {
    return { valid: false, reason: "stale_timestamp" };
  }
  const expected = Buffer.from(computeSignature(secret, timestamp, rawBody));
  const match = signatures.some((candidate) => {
    const actual = Buffer.from(candidate);
    return (
      actual.length === expected.length &&
      crypto.timingSafeEqual(actual, expected)
    );
  });
  return match
    ? { valid: true, timestamp }
    : { valid: false, reason: "signature_mismatch" };
}

module.exports = {
  computeSignature,
  signatureHeader,
  parseSignatureHeader,
  verifySignature
};
