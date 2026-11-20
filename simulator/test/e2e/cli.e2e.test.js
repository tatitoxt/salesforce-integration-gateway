"use strict";

// Drives the real CLI entrypoint as a user would: one process runs the mock
// receiver, another signs and sends events to it over HTTP.
const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { spawn, execFile } = require("node:child_process");

const BIN = path.join(__dirname, "..", "..", "bin", "webhook-simulator.js");
const SECRET = "whsec_e2e_fixture";

function cli(args, env = {}) {
  return new Promise((resolve) => {
    execFile(
      process.execPath,
      [BIN, ...args],
      { env: { ...process.env, ...env } },
      (error, stdout, stderr) => {
        resolve({ code: error ? error.code : 0, stdout, stderr });
      }
    );
  });
}

test("simulator CLI end to end against the mock receiver", async (t) => {
  const port = 20000 + Math.floor(Math.random() * 20000);
  const child = spawn(
    process.execPath,
    [BIN, "serve", "--port", String(port)],
    {
      env: { ...process.env, WEBHOOK_SECRET: SECRET },
      stdio: ["ignore", "pipe", "pipe"]
    }
  );
  t.after(() => child.kill("SIGTERM"));
  const url = await new Promise((resolve, reject) => {
    let output = "";
    child.stdout.on("data", (chunk) => {
      output += chunk;
      const match = output.match(/(http:\/\/127\.0\.0\.1:\d+\/\S+)/);
      if (match) {
        resolve(match[1]);
      }
    });
    child.on("exit", (code) =>
      reject(new Error(`receiver exited with ${code}: ${output}`))
    );
  });

  const accepted = await cli(
    ["send", "--url", url, "--scenario", "full-payment"],
    { WEBHOOK_SECRET: SECRET }
  );
  assert.equal(accepted.code, 0, accepted.stderr);
  assert.match(accepted.stdout, /^202 accepted evt_sim_/);

  const duplicate = await cli([
    "send",
    "--url",
    url,
    "--secret",
    SECRET,
    "--scenario",
    "duplicate",
    "--json"
  ]);
  assert.equal(duplicate.code, 0, duplicate.stderr);
  assert.deepEqual(
    JSON.parse(duplicate.stdout).map((result) => result.body.status),
    ["accepted", "duplicate"]
  );

  const tampered = await cli([
    "send",
    "--url",
    url,
    "--secret",
    SECRET,
    "--invoice",
    "INV-1",
    "--tamper"
  ]);
  assert.equal(tampered.code, 1);
  assert.match(tampered.stdout, /^401 rejected \(signature_mismatch\)/);

  const wrongSecret = await cli([
    "send",
    "--url",
    url,
    "--secret",
    "wrong",
    "--invoice",
    "INV-1"
  ]);
  assert.equal(wrongSecret.code, 1);

  const usage = await cli(["send", "--url", url]);
  assert.equal(usage.code, 2);
  assert.match(usage.stderr, /Missing signing secret/);
});
