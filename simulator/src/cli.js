"use strict";

const { parseArgs } = require("node:util");
const {
  SCENARIOS,
  bulk,
  paymentSucceeded,
  refundCreated
} = require("./events");
const { sendAll } = require("./sender");
const { signatureHeader } = require("./signature");
const { createMockReceiver } = require("./mockReceiver");

const USAGE = `Usage: webhook-simulator <command> [options]

Commands:
  scenarios                      List built-in synthetic scenarios
  send                           Sign and POST events to a webhook URL
  sign                           Print a Stripe-Signature header for a body
  serve                          Run a local mock receiver (no Salesforce org needed)

Options:
  --url <url>            Target URL (send)
  --secret <secret>      Signing secret (or WEBHOOK_SECRET env var)
  --scenario <name>      Scenario to send (send)
  --invoice <number>     Invoice number for a single payment (send)
  --amount <n>           Amount in major units (send, default 100)
  --currency <code>      ISO currency (send, default usd)
  --refund-of <pi_id>    Send a refund for this payment id instead (send)
  --bulk <n>             Send n payments for INV-BULK-0000.. (send)
  --tamper               Alter the body after signing (send; expect 401)
  --timestamp <unix>     Override the signature timestamp (send, sign)
  --body <json>          Raw body to sign (sign)
  --port <n>             Port for serve (default 8787)
  --json                 Machine-readable output
  -h, --help             Show this help
`;

const OPTIONS = {
  url: { type: "string" },
  secret: { type: "string" },
  scenario: { type: "string" },
  invoice: { type: "string" },
  amount: { type: "string" },
  currency: { type: "string" },
  "refund-of": { type: "string" },
  bulk: { type: "string" },
  tamper: { type: "boolean" },
  timestamp: { type: "string" },
  body: { type: "string" },
  port: { type: "string" },
  json: { type: "boolean" },
  help: { type: "boolean", short: "h" }
};

class UsageError extends Error {}

function resolveSecret(values, env) {
  const secret = values.secret || env.WEBHOOK_SECRET;
  if (!secret) {
    throw new UsageError(
      "Missing signing secret: pass --secret or set WEBHOOK_SECRET"
    );
  }
  return secret;
}

function positiveInteger(value, name) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new UsageError(`--${name} must be a positive integer`);
  }
  return parsed;
}

function buildEvents(values) {
  const chosen = ["scenario", "invoice", "refund-of", "bulk"].filter(
    (key) => values[key]
  );
  if (chosen.length !== 1) {
    throw new UsageError(
      "send needs exactly one of --scenario, --invoice, --refund-of, --bulk"
    );
  }
  const amount = values.amount ?? "100";
  const currency = values.currency ?? "usd";
  if (values.scenario) {
    const scenario = SCENARIOS[values.scenario];
    if (!scenario) {
      throw new UsageError(
        `Unknown scenario "${values.scenario}". Run "scenarios" to list them.`
      );
    }
    return scenario();
  }
  if (values.bulk) {
    return bulk({
      count: positiveInteger(values.bulk, "bulk"),
      amount,
      currency
    });
  }
  if (values["refund-of"]) {
    return [
      refundCreated({ paymentId: values["refund-of"], amount, currency })
    ];
  }
  return [
    paymentSucceeded({ invoiceNumber: values.invoice, amount, currency })
  ];
}

async function run(
  argv,
  { env = process.env, stdout = process.stdout, fetchImpl } = {}
) {
  let parsed;
  try {
    parsed = parseArgs({
      args: argv,
      options: OPTIONS,
      allowPositionals: true
    });
  } catch (error) {
    throw new UsageError(error.message);
  }
  const { values, positionals } = parsed;
  const command = positionals[0];
  const write = (line) => stdout.write(`${line}\n`);

  if (values.help || !command) {
    write(USAGE);
    return { exitCode: command || values.help ? 0 : 2 };
  }

  if (command === "scenarios") {
    for (const name of Object.keys(SCENARIOS)) {
      write(name);
    }
    return { exitCode: 0 };
  }

  if (command === "sign") {
    if (values.body === undefined) {
      throw new UsageError("sign needs --body");
    }
    const timestamp = values.timestamp
      ? positiveInteger(values.timestamp, "timestamp")
      : Math.floor(Date.now() / 1000);
    write(signatureHeader(resolveSecret(values, env), timestamp, values.body));
    return { exitCode: 0 };
  }

  if (command === "send") {
    if (!values.url) {
      throw new UsageError("send needs --url");
    }
    const secret = resolveSecret(values, env);
    const events = buildEvents(values);
    const results = await sendAll(events, {
      url: values.url,
      secret,
      tamper: Boolean(values.tamper),
      timestamp: values.timestamp
        ? positiveInteger(values.timestamp, "timestamp")
        : undefined,
      ...(fetchImpl ? { fetchImpl } : {})
    });
    if (values.json) {
      write(JSON.stringify(results));
    } else {
      for (const result of results) {
        const status =
          typeof result.body === "object" ? result.body.status : result.body;
        const detail =
          result.body && result.body.error ? ` (${result.body.error})` : "";
        write(`${result.status} ${status}${detail} ${result.eventId}`);
      }
    }
    const failed = results.some((result) => result.status >= 300);
    return { exitCode: failed ? 1 : 0, results };
  }

  if (command === "serve") {
    const port = values.port ? positiveInteger(values.port, "port") : 8787;
    const { server } = createMockReceiver({
      secret: values.secret || env.WEBHOOK_SECRET
    });
    await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));
    write(
      `Mock receiver listening on http://127.0.0.1:${server.address().port}/services/apexrest/payments/webhook`
    );
    return { exitCode: null, server };
  }

  throw new UsageError(`Unknown command "${command}"`);
}

module.exports = { run, UsageError, USAGE };
