#!/usr/bin/env node
"use strict";

const { run, UsageError } = require("../src/cli");

run(process.argv.slice(2))
  .then(({ exitCode, server }) => {
    if (server) {
      const shutdown = () => server.close(() => process.exit(0));
      process.on("SIGINT", shutdown);
      process.on("SIGTERM", shutdown);
      return;
    }
    process.exitCode = exitCode;
  })
  .catch((error) => {
    process.stderr.write(
      `${error instanceof UsageError ? "Usage error" : "Error"}: ${error.message}\n`
    );
    process.exitCode = error instanceof UsageError ? 2 : 1;
  });
