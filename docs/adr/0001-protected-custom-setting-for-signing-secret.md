# ADR 0001: Signing secret in a protected hierarchy Custom Setting

- Status: accepted

## Context

The webhook signing secret must not be hardcoded or committed. Options were a protected
Custom Metadata Type, a protected Custom Setting, or a Named/External Credential.

## Decision

Store the secret in `Payment_Gateway_Settings__c`, a **protected** hierarchy Custom
Setting, together with tolerance and retry limits. No record is shipped in source; the
admin creates the org-default record after deploying (`scripts/apex/configure-gateway.apex.example`).

## Consequences

- Apex tests can create the setting with DML, so the full signature path is testable
  without a real secret. Custom Metadata records cannot be inserted from Apex tests.
- "Protected" visibility only hides the data from subscriber orgs when shipped in a
  **managed** package. In an unmanaged deployment, users with "Customize Application" /
  "View Setup" can read it. This is documented as a limitation.
- If the secret is missing the endpoint fails closed (HTTP 503).
