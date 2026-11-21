# ADR 0002: Accept fast, process asynchronously, retry with backoff

- Status: accepted

## Context

Processors expect a quick 2xx and retry otherwise. Matching and invoice roll-ups touch
several objects and can fail transiently (row locks, events arriving out of order).

## Decision

- The REST resource only verifies, de-duplicates and inserts `Payment_Event__c`
  (status `Received`), then returns 202.
- An after-insert trigger enqueues one `PaymentEventProcessor` Queueable per transaction.
- Failures increment `Attempts__c`; the event becomes `Retry_Scheduled` with
  `Next_Attempt_At__c = now + 2^attempts minutes` (capped at 60) until
  `Max_Event_Attempts__c`, then `Dead_Letter`.
- Queueables can enqueue at most one child from async context, so a `GatewaySweeper`
  Schedulable re-enqueues anything due. Retries never depend on a single chain.
- A `System.Finalizer` (`PaymentEventRetryFinalizer`) is attached to each processor
  job: when the job dies on an unhandled exception or a governor limit — where no
  catch block can run — the finalizer re-enqueues it immediately. Crash depth is
  carried in job state and capped at `MAX_CRASH_RETRIES` so a persistent poison
  job falls back to the sweeper instead of hot-looping.
- Billing sync follows the same pattern in `BillingSyncQueueable` (callouts first, DML after).

## Consequences

- Delivery latency is bounded by Queueable start time plus the sweeper interval;
  crash recovery is bounded by the finalizer (immediate) or the sweeper after
  `MAX_CRASH_RETRIES` consecutive crashes.
- The endpoint is called with an OAuth access token of an integration user; exposing it
  anonymously through a Salesforce Site is out of scope for this repository.
