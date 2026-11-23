# Specification: Salesforce Integration Gateway

## Problem

A business that invoices customers in Salesforce and collects money through a card
processor (Stripe-style webhooks) needs three things to stay consistent:

1. Payment events must reach Salesforce **authenticated** (nobody else can forge a
   "payment succeeded") and **exactly once** in effect, even though the processor
   retries deliveries and may send events out of order.
2. Each payment or refund must be **matched to the right invoice**, including partial
   payments and overpayments, and anything that cannot be matched automatically must
   land in a reviewable **exceptions queue** instead of being silently dropped.
3. The external **billing platform** must learn about the new invoice balance, with
   retries when it is temporarily unavailable.

## Personas

- **Integration (processor):** sends signed webhook deliveries over HTTPS.
- **Finance operator:** works the exceptions queue in the reconciliation console.
- **Salesforce admin/developer:** configures the signing secret, Named Credential and
  schedules the sweeper.

## Requirements

| ID  | Requirement                                                                                                                                                                                       |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| R1  | `POST /services/apexrest/payments/webhook` verifies a `Stripe-Signature` header (`t=<unix>,v1=<hex HMAC-SHA256>`) over `"<t>.<raw body>"` using a secret stored in a protected Custom Setting.    |
| R2  | Deliveries whose timestamp is outside the tolerance window (default 300 s) are rejected.                                                                                                          |
| R3  | Missing/blank secret fails closed (HTTP 503), never accepts unsigned traffic.                                                                                                                     |
| R4  | Each event is persisted once in `Payment_Event__c`, keyed by the unique external id `External_Event_Id__c`. A redelivery returns HTTP 200 `duplicate` and creates nothing.                        |
| R5  | Processing is asynchronous (Queueable). Failures are retried with exponential backoff; after `Max_Event_Attempts__c` the event moves to `Dead_Letter`.                                            |
| R6  | `payment_intent.succeeded` creates a `Payment__c` matched to an `Invoice__c` by `metadata.invoice_number`; invoice paid amount, balance and status (`Partially_Paid`, `Paid`, `Overpaid`) update. |
| R7  | `charge.refunded` creates a refund `Payment__c` linked to the original payment and reduces the invoice paid amount. A refund that arrives before its payment is retried (out-of-order delivery).  |
| R8  | Unknown invoice, currency mismatch or overpayment put the event in `Needs_Review` (exceptions queue) with a reason code.                                                                          |
| R9  | Invoices whose paid amount changes are synced to the billing platform through the `Billing_Platform` Named Credential; 429/5xx/timeouts retry with backoff, other 4xx fail without retry.         |
| R10 | The reconciliation console (LWC) lists exception events, shows the raw payload, retries an event and manually matches its payment to an open invoice.                                             |
| R11 | All trigger, service and selector code is bulk-safe: 200 events in one transaction stay within governor limits.                                                                                   |
| R12 | A CLI simulator signs and sends synthetic events (no real data, no real processor account).                                                                                                       |

## Acceptance scenarios (Given / When / Then → automated test)

| Scenario                                                                                                                                                              | Test                                                                                                                 |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Given a valid signature, when an event is posted, then it is stored as `Received`, HTTP 202, and processing is enqueued.                                              | `PaymentWebhookResourceTest.validSignatureStoresEventAndEnqueuesProcessing`                                          |
| Given a tampered body or wrong secret, when posted, then HTTP 401 and nothing is stored.                                                                              | `PaymentWebhookResourceTest.badSignatureIsRejected`, `WebhookSignatureVerifierTest`                                  |
| Given a timestamp older than the tolerance, then HTTP 401 `stale_timestamp`.                                                                                          | `WebhookSignatureVerifierTest.rejectsTimestampOutsideTolerance`                                                      |
| Given the same event id twice, then the second call returns `duplicate` and only one record exists.                                                                   | `PaymentWebhookResourceTest.duplicateEventIsAcknowledgedOnce`                                                        |
| Given an open invoice of 100.00 and a payment of 40.00, then the invoice is `Partially_Paid` with balance 60.00.                                                      | `PaymentEventServiceTest.partialPaymentLeavesBalance`                                                                |
| Given a paid invoice and a refund of 25.00, then paid amount drops by 25.00 and status becomes `Partially_Paid`.                                                      | `PaymentEventServiceTest.refundReducesPaidAmount`                                                                    |
| Given a refund whose payment has not arrived yet, then the event is `Retry_Scheduled`; after max attempts it is `Dead_Letter`.                                        | `PaymentEventServiceTest.refundBeforePaymentIsRetriedThenDeadLettered`                                               |
| Given 200 payment events for 200 invoices, when processed in one Queueable, then all invoices are `Paid` within limits.                                               | `PaymentEventServiceTest.bulkProcessesTwoHundredEvents`                                                              |
| Given the billing API returns 503, then the invoice is `Retry_Scheduled`; 200 → `Synced`; 400 → `Failed`.                                                             | `BillingSyncServiceTest`                                                                                             |
| Given an event in `Needs_Review`, when the operator matches it to an invoice, then the payment is `Applied` and the event closes.                                     | `ReconciliationControllerTest.manualMatchAppliesPayment`, `reconciliationConsole.test.js`                            |
| Given the simulator CLI, when it sends a scenario to an HTTP endpoint, then each request carries a verifiable signature.                                              | `simulator/test/e2e/cli.e2e.test.js`                                                                                 |
| Given a `payment_intent.payment_failed` event, then no payment is recorded and the event lands in `Needs_Review` with the decline code/message and invoice reference. | `PaymentEventServiceTest.failedPaymentIsQueuedForReviewWithDeclineDetail`, `failedPaymentWithoutInvoiceStillReviews` |

## Out of scope

- Real processor or billing-platform accounts, multi-currency conversion, tax.
- Dispute evidence submission, payouts, subscriptions.
- A public Salesforce Site / guest-user exposure of the endpoint (see ADR 0002).
