"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const {
  computeSignature,
  signatureHeader,
  parseSignatureHeader,
  verifySignature
} = require("../../src/signature");

const SECRET = "whsec_test_fixture_not_a_real_secret";
const NOW = 1767225600;
const BODY = '{"id":"evt_sig_1","type":"payment_intent.succeeded"}';

test("matches the HMAC vector used by WebhookSignatureVerifierTest.cls", () => {
  const expected = crypto
    .createHmac("sha256", "key")
    .update("1.body")
    .digest("hex");
  assert.equal(computeSignature("key", 1, "body"), expected);
  assert.equal(expected.length, 64);
});

test("signs the exact bytes of non-ASCII bodies", () => {
  const body = '{"customer":"Müller"}';
  const expected = crypto
    .createHmac("sha256", SECRET)
    .update(`${NOW}.${body}`, "utf8")
    .digest("hex");
  assert.equal(computeSignature(SECRET, NOW, body), expected);
});

test("requires a secret", () => {
  assert.throws(() => computeSignature("", NOW, BODY), /signing secret/);
});

test("builds and parses Stripe-style headers", () => {
  const header = signatureHeader(SECRET, NOW, BODY);
  assert.match(header, /^t=1767225600,v1=[0-9a-f]{64}$/);
  const parsed = parseSignatureHeader(`${header}, v1=ABC, junk, =x`);
  assert.equal(parsed.timestamp, NOW);
  assert.deepEqual(parsed.signatures.slice(1), ["abc"]);
  assert.deepEqual(parseSignatureHeader(undefined), {
    timestamp: null,
    signatures: []
  });
});

test("verifies valid signatures and rejects every failure mode", () => {
  const header = signatureHeader(SECRET, NOW, BODY);
  const check = (overrides) =>
    verifySignature({
      header,
      rawBody: BODY,
      secret: SECRET,
      nowSeconds: NOW,
      ...overrides
    });
  assert.deepEqual(check({}), { valid: true, timestamp: NOW });
  assert.equal(check({ header: "" }).reason, "missing_signature");
  assert.equal(check({ header: "v1=abc" }).reason, "malformed_signature");
  assert.equal(check({ header: `t=${NOW}` }).reason, "malformed_signature");
  assert.equal(check({ nowSeconds: NOW + 301 }).reason, "stale_timestamp");
  assert.equal(check({ nowSeconds: NOW + 300 }).valid, true);
  assert.equal(check({ secret: "other" }).reason, "signature_mismatch");
  assert.equal(check({ rawBody: `${BODY} ` }).reason, "signature_mismatch");
  assert.equal(
    check({ header: `t=${NOW},v1=short` }).reason,
    "signature_mismatch"
  );
});

test("accepts any matching v1 entry (secret rotation)", () => {
  const valid = signatureHeader(SECRET, NOW, BODY).split("v1=")[1];
  const header = `t=${NOW},v1=${"0".repeat(64)},v1=${valid.toUpperCase()}`;
  assert.equal(
    verifySignature({ header, rawBody: BODY, secret: SECRET, nowSeconds: NOW })
      .valid,
    true
  );
});
