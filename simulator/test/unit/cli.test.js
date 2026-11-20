"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { run, UsageError } = require("../../src/cli");

function capture() {
  const lines = [];
  return { lines, stdout: { write: (text) => lines.push(text.trimEnd()) } };
}

test("lists scenarios", async () => {
  const out = capture();
  const { exitCode } = await run(["scenarios"], {
    stdout: out.stdout,
    env: {}
  });
  assert.equal(exitCode, 0);
  assert.ok(out.lines.includes("full-payment"));
});

test("prints help and exits 2 without a command", async () => {
  const out = capture();
  assert.equal((await run([], { stdout: out.stdout, env: {} })).exitCode, 2);
  assert.match(out.lines[0], /Usage: webhook-simulator/);
  assert.equal(
    (await run(["--help"], { stdout: out.stdout, env: {} })).exitCode,
    0
  );
});

test("sign uses WEBHOOK_SECRET and a fixed timestamp", async () => {
  const out = capture();
  await run(["sign", "--body", "body", "--timestamp", "1"], {
    stdout: out.stdout,
    env: { WEBHOOK_SECRET: "key" }
  });
  assert.match(out.lines[0], /^t=1,v1=[0-9a-f]{64}$/);
});

test("send posts signed events through the injected fetch", async () => {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    return {
      status: 202,
      text: async () => JSON.stringify({ status: "accepted" })
    };
  };
  const out = capture();
  const { exitCode, results } = await run(
    [
      "send",
      "--url",
      "http://x/hook",
      "--secret",
      "s",
      "--invoice",
      "INV-9",
      "--amount",
      "12.34"
    ],
    { stdout: out.stdout, env: {}, fetchImpl }
  );
  assert.equal(exitCode, 0);
  assert.equal(results.length, 1);
  assert.equal(calls[0].init.method, "POST");
  assert.match(calls[0].init.headers["Stripe-Signature"], /^t=\d+,v1=/);
  assert.equal(JSON.parse(calls[0].init.body).data.object.amount, 1234);
  assert.match(out.lines[0], /^202 accepted evt_sim_/);
});

test("send exits 1 when the receiver rejects and supports --json", async () => {
  const fetchImpl = async () => ({
    status: 401,
    text: async () => '{"status":"rejected","error":"signature_mismatch"}'
  });
  const out = capture();
  const { exitCode } = await run(
    [
      "send",
      "--url",
      "http://x",
      "--secret",
      "s",
      "--scenario",
      "full-payment",
      "--json"
    ],
    { stdout: out.stdout, env: {}, fetchImpl }
  );
  assert.equal(exitCode, 1);
  assert.equal(JSON.parse(out.lines[0])[0].body.error, "signature_mismatch");
});

test("handles non-JSON responses", async () => {
  const fetchImpl = async () => ({
    status: 500,
    text: async () => "Internal error"
  });
  const out = capture();
  const { exitCode } = await run(
    ["send", "--url", "http://x", "--secret", "s", "--refund-of", "pi_1"],
    {
      stdout: out.stdout,
      env: {},
      fetchImpl
    }
  );
  assert.equal(exitCode, 1);
  assert.match(out.lines[0], /^500 Internal error/);
});

test("rejects invalid usage", async () => {
  const env = {};
  const stdout = capture().stdout;
  const cases = [
    [["send", "--secret", "s", "--scenario", "refund"], /--url/],
    [
      ["send", "--url", "http://x", "--scenario", "refund"],
      /Missing signing secret/
    ],
    [["send", "--url", "http://x", "--secret", "s"], /exactly one/],
    [
      ["send", "--url", "http://x", "--secret", "s", "--scenario", "nope"],
      /Unknown scenario/
    ],
    [
      ["send", "--url", "http://x", "--secret", "s", "--bulk", "0"],
      /positive integer/
    ],
    [["sign", "--secret", "s"], /--body/],
    [["explode"], /Unknown command/],
    [["send", "--bogus"], /Unknown option/]
  ];
  for (const [argv, message] of cases) {
    await assert.rejects(
      run(argv, { env, stdout }),
      (error) => error instanceof UsageError && message.test(error.message)
    );
  }
});
