const { jestConfig } = require("@salesforce/sfdx-lwc-jest/config");

module.exports = {
  ...jestConfig,
  modulePathIgnorePatterns: ["<rootDir>/.localdevserver"],
  testPathIgnorePatterns: ["<rootDir>/node_modules/", "<rootDir>/simulator/"],
  collectCoverageFrom: ["force-app/**/lwc/**/*.js", "!**/__tests__/**"],
  coverageThreshold: {
    global: { branches: 80, functions: 85, lines: 90, statements: 90 }
  }
};
