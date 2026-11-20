const lwcConfig = require("@salesforce/eslint-config-lwc");
const jestPlugin = require("eslint-plugin-jest");
const globals = require("globals");

module.exports = [
  {
    ignores: ["node_modules/**", "coverage/**", ".sf/**", ".sfdx/**"]
  },
  ...lwcConfig.configs.recommended.map((config) => ({
    ...config,
    files: ["force-app/**/lwc/**/*.js"]
  })),
  {
    files: ["force-app/**/lwc/**/__tests__/**/*.js"],
    plugins: { jest: jestPlugin },
    languageOptions: { globals: { ...globals.jest, ...globals.node } },
    rules: {
      ...jestPlugin.configs.recommended.rules,
      "@lwc/lwc/no-unexpected-wire-adapter-usages": "off"
    }
  },
  {
    files: ["simulator/**/*.js", "eslint.config.js", "jest.config.js"],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: "commonjs",
      globals: { ...globals.node }
    },
    rules: {
      "no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
      eqeqeq: "error",
      "no-var": "error",
      "prefer-const": "error"
    }
  }
];
