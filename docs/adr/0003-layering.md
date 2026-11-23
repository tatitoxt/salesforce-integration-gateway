# ADR 0003: Trigger handler → service → selector layering

- Status: accepted

## Decision

- One trigger per object, no logic in triggers; each delegates to a `TriggerHandler`
  subclass (`PaymentEventTriggerHandler`, `PaymentTriggerHandler`, `InvoiceTriggerHandler`).
- Business rules live in services (`PaymentEventService`, `PaymentMatchingService`,
  `InvoiceRollupService`, `BillingSyncService`) that take collections.
- All SOQL lives in selectors (`InvoiceSelector`, `PaymentSelector`, `PaymentEventSelector`).
- Handlers support a static bypass, used by services to avoid recursive roll-ups.

## Consequences

Each layer is unit-testable in isolation and every public method is bulk-safe by
signature (collections in, collections out).
