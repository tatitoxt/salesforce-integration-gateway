/**
 * Turns parsed payment events into Payment__c records matched to invoices.
 * Bulk-safe: a fixed number of queries/DML statements per call regardless of
 * batch size. Every event leaves with a terminal or retry status.
 * Runs inside the system-mode PaymentEventProcessor job, hence no CRUD checks.
 */
@SuppressWarnings(
  'PMD.CognitiveComplexity,PMD.CyclomaticComplexity,PMD.StdCyclomaticComplexity,PMD.NcssMethodCount,PMD.ApexCRUDViolation'
)
public inherited sharing class PaymentEventService {
  public static final String REASON_MISSING_INVOICE_REFERENCE = 'MISSING_INVOICE_REFERENCE';
  public static final String REASON_INVOICE_NOT_FOUND = 'INVOICE_NOT_FOUND';
  public static final String REASON_INVOICE_NOT_PAYABLE = 'INVOICE_NOT_PAYABLE';
  public static final String REASON_CURRENCY_MISMATCH = 'CURRENCY_MISMATCH';
  public static final String REASON_OVERPAYMENT = 'OVERPAYMENT';
  public static final String REASON_MISSING_PAYMENT_REFERENCE = 'MISSING_PAYMENT_REFERENCE';
  public static final String REASON_ORIGINAL_NOT_FOUND = 'ORIGINAL_PAYMENT_NOT_FOUND';
  public static final String REASON_ORIGINAL_NOT_APPLIED = 'ORIGINAL_PAYMENT_NOT_APPLIED';
  public static final String REASON_REFUND_EXCEEDS_PAYMENT = 'REFUND_EXCEEDS_PAYMENT';
  public static final String REASON_DISPUTE_OPENED = 'DISPUTE_OPENED';
  public static final String REASON_DISPUTE_WON = 'DISPUTE_WON';
  public static final String REASON_DISPUTE_LOST = 'DISPUTE_LOST';
  public static final String REASON_DISPUTE_NOT_FOUND = 'DISPUTE_NOT_FOUND';
  public static final String REASON_UNKNOWN_DISPUTE_STATUS = 'UNKNOWN_DISPUTE_STATUS';
  public static final String REASON_INVOICE_BALANCE_REMAINING = 'INVOICE_BALANCE_REMAINING';
  public static final String REASON_PAYMENT_FAILED = 'PAYMENT_FAILED';
  public static final String REASON_REFUND_BELOW_LEDGER = 'REFUND_BELOW_LEDGER';
  public static final String REASON_INVALID_PAYLOAD = 'INVALID_PAYLOAD';
  public static final String REASON_DML_ERROR = 'DML_ERROR';
  public static final String REASON_UNEXPECTED_ERROR = 'UNEXPECTED_ERROR';

  private final InvoiceSelector invoiceSelector = new InvoiceSelector();
  private final PaymentSelector paymentSelector = new PaymentSelector();
  private Integer maxAttempts;

  public void process(List<Payment_Event__c> events) {
    maxAttempts = GatewaySettings.maxEventAttempts();
    Map<Id, PaymentEventPayload> payloads = new Map<Id, PaymentEventPayload>();
    List<Payment_Event__c> paymentEvents = new List<Payment_Event__c>();
    List<Payment_Event__c> refundEvents = new List<Payment_Event__c>();
    List<Payment_Event__c> disputeEvents = new List<Payment_Event__c>();
    List<Payment_Event__c> disputeClosedEvents = new List<Payment_Event__c>();
    List<Payment_Event__c> invoicePaidEvents = new List<Payment_Event__c>();
    List<Payment_Event__c> paymentFailedEvents = new List<Payment_Event__c>();
    List<Payment_Event__c> chargeRefundedEvents = new List<Payment_Event__c>();
    for (Payment_Event__c record : events) {
      record.Attempts__c =
        (record.Attempts__c == null ? 0 : record.Attempts__c) + 1;
      PaymentEventPayload payload;
      try {
        payload = PaymentEventPayload.parse(record.Payload__c);
      } catch (PaymentEventPayload.PayloadException e) {
        markDeadLetter(record, REASON_INVALID_PAYLOAD, e.getMessage());
        continue;
      }
      payloads.put(record.Id, payload);
      if (payload.isPayment()) {
        paymentEvents.add(record);
      } else if (payload.isRefund()) {
        refundEvents.add(record);
      } else if (payload.isDispute()) {
        disputeEvents.add(record);
      } else if (payload.isDisputeClosed()) {
        disputeClosedEvents.add(record);
      } else if (payload.isInvoicePaid()) {
        invoicePaidEvents.add(record);
      } else if (payload.isPaymentFailed()) {
        paymentFailedEvents.add(record);
      } else if (payload.isChargeRefunded()) {
        chargeRefundedEvents.add(record);
      } else {
        markFinal(record, 'Ignored', null);
      }
    }

    Savepoint beforeApply = Database.setSavepoint();
    try {
      applyPayments(paymentEvents, payloads);
      applyRefunds(refundEvents, payloads);
      applyDisputes(disputeEvents, payloads);
      applyDisputeClosures(disputeClosedEvents, payloads);
      applyInvoicePaid(invoicePaidEvents, payloads);
      applyPaymentFailures(paymentFailedEvents, payloads);
      applyChargeRefunds(chargeRefundedEvents, payloads);
    } catch (Exception e) {
      Database.rollback(beforeApply);
      List<Payment_Event__c> affected = new List<Payment_Event__c>(
        paymentEvents
      );
      affected.addAll(refundEvents);
      affected.addAll(disputeEvents);
      affected.addAll(disputeClosedEvents);
      affected.addAll(invoicePaidEvents);
      affected.addAll(paymentFailedEvents);
      affected.addAll(chargeRefundedEvents);
      for (Payment_Event__c record : affected) {
        scheduleRetry(
          record,
          REASON_UNEXPECTED_ERROR,
          e.getTypeName() + ': ' + e.getMessage()
        );
      }
    }
    update events;
  }

  private void applyPayments(
    List<Payment_Event__c> events,
    Map<Id, PaymentEventPayload> payloads
  ) {
    if (events.isEmpty()) {
      return;
    }
    Set<String> externalIds = new Set<String>();
    Set<String> invoiceNumbers = new Set<String>();
    for (Payment_Event__c record : events) {
      PaymentEventPayload payload = payloads.get(record.Id);
      externalIds.add(payload.objectId);
      if (String.isNotBlank(payload.invoiceNumber)) {
        invoiceNumbers.add(payload.invoiceNumber);
      }
    }
    Set<String> knownPaymentIds = externalIdsOf(
      paymentSelector.selectByExternalIds(externalIds)
    );
    Map<String, Invoice__c> invoicesByNumber = new Map<String, Invoice__c>();
    for (
      Invoice__c invoice : invoiceSelector.selectByInvoiceNumbers(
        invoiceNumbers
      )
    ) {
      invoicesByNumber.put(invoice.Invoice_Number__c.toUpperCase(), invoice);
    }

    // Payments without an invoice reference get one more shot: when exactly
    // one payable invoice matches currency + outstanding balance, it is the
    // match. Ambiguous or empty candidate sets fall through to Unmatched.
    Set<String> unmatchedCurrencies = new Set<String>();
    Set<Decimal> unmatchedAmounts = new Set<Decimal>();
    for (Payment_Event__c record : events) {
      PaymentEventPayload payload = payloads.get(record.Id);
      if (
        String.isBlank(payload.invoiceNumber) &&
        !knownPaymentIds.contains(payload.objectId) &&
        String.isNotBlank(payload.currencyCode) &&
        payload.amount != null
      ) {
        unmatchedCurrencies.add(payload.currencyCode);
        unmatchedAmounts.add(payload.amount);
      }
    }
    Map<String, List<Invoice__c>> byBalance = new Map<String, List<Invoice__c>>();
    for (
      Invoice__c invoice : invoiceSelector.selectPayableByCurrenciesAndAmounts(
        unmatchedCurrencies,
        unmatchedAmounts
      )
    ) {
      String key =
        invoice.Currency_Code__c.toUpperCase() +
        '|' +
        invoice.Balance_Due__c;
      if (!byBalance.containsKey(key)) {
        byBalance.put(key, new List<Invoice__c>());
      }
      byBalance.get(key).add(invoice);
    }

    Map<Id, Decimal> remainingByInvoice = new Map<Id, Decimal>();
    List<Payment__c> toInsert = new List<Payment__c>();
    List<Payment_Event__c> insertedFor = new List<Payment_Event__c>();
    List<String> reviewReasons = new List<String>();
    for (Payment_Event__c record : events) {
      PaymentEventPayload payload = payloads.get(record.Id);
      if (knownPaymentIds.contains(payload.objectId)) {
        markFinal(
          record,
          'Processed',
          'Payment ' + payload.objectId + ' already recorded'
        );
        continue;
      }
      knownPaymentIds.add(payload.objectId);

      Payment__c payment = newPayment(record, payload, 'Payment');
      String reason;
      Invoice__c invoice = String.isBlank(payload.invoiceNumber)
        ? null
        : invoicesByNumber.get(payload.invoiceNumber.toUpperCase());
      List<Invoice__c> amountCandidates = String.isBlank(
          payload.invoiceNumber
        ) && String.isNotBlank(payload.currencyCode)
        ? byBalance.get(
            payload.currencyCode.toUpperCase() + '|' + payload.amount
          )
        : null;
      Invoice__c exactAmountInvoice = null;
      if (amountCandidates != null) {
        // Only an invoice whose *remaining* balance still equals the amount
        // is a candidate; claims made earlier in this batch already count.
        List<Invoice__c> open = new List<Invoice__c>();
        for (Invoice__c candidate : amountCandidates) {
          Decimal remaining = remainingByInvoice.containsKey(candidate.Id)
            ? remainingByInvoice.get(candidate.Id)
            : candidate.Balance_Due__c;
          if (remaining == payload.amount) {
            open.add(candidate);
          }
        }
        if (open.size() == 1) {
          exactAmountInvoice = open[0];
        }
      }
      if (invoice == null && exactAmountInvoice != null) {
        invoice = exactAmountInvoice;
      }
      if (String.isBlank(payload.invoiceNumber) && invoice == null) {
        reason = REASON_MISSING_INVOICE_REFERENCE;
        payment.Status__c = 'Unmatched';
      } else if (invoice == null) {
        reason = REASON_INVOICE_NOT_FOUND;
        payment.Status__c = 'Unmatched';
      } else if (
        !InvoiceSelector.PAYABLE_STATUSES.contains(invoice.Status__c)
      ) {
        reason = REASON_INVOICE_NOT_PAYABLE;
        payment.Status__c = 'Exception';
        payment.Invoice__c = invoice.Id;
      } else if (
        !currencyMatches(invoice.Currency_Code__c, payload.currencyCode)
      ) {
        reason = REASON_CURRENCY_MISMATCH;
        payment.Status__c = 'Exception';
        payment.Invoice__c = invoice.Id;
      } else {
        payment.Status__c = 'Applied';
        payment.Match_Method__c = String.isBlank(payload.invoiceNumber)
          ? 'Exact_Amount'
          : 'Invoice_Number';
        payment.Invoice__c = invoice.Id;
        Decimal remaining = remainingByInvoice.containsKey(invoice.Id)
          ? remainingByInvoice.get(invoice.Id)
          : invoice.Balance_Due__c;
        remaining -= payload.amount;
        remainingByInvoice.put(invoice.Id, remaining);
        if (remaining < 0) {
          reason = REASON_OVERPAYMENT;
        }
      }
      payment.Exception_Reason__c = payment.Status__c == 'Applied'
        ? null
        : reason;
      toInsert.add(payment);
      insertedFor.add(record);
      reviewReasons.add(reason);
    }
    saveAndClassify(toInsert, insertedFor, reviewReasons);
  }

  private void applyRefunds(
    List<Payment_Event__c> events,
    Map<Id, PaymentEventPayload> payloads
  ) {
    if (events.isEmpty()) {
      return;
    }
    Set<String> refundIds = new Set<String>();
    Set<String> originalExternalIds = new Set<String>();
    for (Payment_Event__c record : events) {
      PaymentEventPayload payload = payloads.get(record.Id);
      refundIds.add(payload.objectId);
      if (String.isNotBlank(payload.paymentIntentId)) {
        originalExternalIds.add(payload.paymentIntentId);
      }
    }
    Set<String> knownRefundIds = externalIdsOf(
      paymentSelector.selectByExternalIds(refundIds)
    );
    Map<String, Payment__c> originalsByExternalId = new Map<String, Payment__c>();
    for (
      Payment__c original : paymentSelector.selectByExternalIds(
        originalExternalIds
      )
    ) {
      originalsByExternalId.put(original.External_Payment_Id__c, original);
    }
    Map<Id, Decimal> refundedByOriginal = new Map<Id, Decimal>();
    Set<Id> originalIds = new Set<Id>();
    for (Payment__c original : originalsByExternalId.values()) {
      originalIds.add(original.Id);
    }
    for (
      AggregateResult row : paymentSelector.sumRefundsByOriginalPayment(
        originalIds
      )
    ) {
      refundedByOriginal.put(
        (Id) row.get('originalId'),
        (Decimal) row.get('total')
      );
    }
    // charge.refunded is the canonical ledger: once it reconciled a charge's
    // cumulative amount_refunded, refund.created events for the same money
    // are already covered and must not record a second refund.
    Set<Id> ledgeredOriginals = paymentSelector.selectChargeLedgeredOriginalIds(
      originalIds
    );

    List<Payment__c> toInsert = new List<Payment__c>();
    List<Payment_Event__c> insertedFor = new List<Payment_Event__c>();
    List<String> reviewReasons = new List<String>();
    for (Payment_Event__c record : events) {
      PaymentEventPayload payload = payloads.get(record.Id);
      if (knownRefundIds.contains(payload.objectId)) {
        markFinal(
          record,
          'Processed',
          'Refund ' + payload.objectId + ' already recorded'
        );
        continue;
      }
      if (String.isBlank(payload.paymentIntentId)) {
        markNeedsReview(record, REASON_MISSING_PAYMENT_REFERENCE);
        continue;
      }
      Payment__c original = originalsByExternalId.get(payload.paymentIntentId);
      if (original == null) {
        // Out-of-order delivery: the payment may still arrive.
        scheduleRetry(
          record,
          REASON_ORIGINAL_NOT_FOUND,
          'Refund ' +
            payload.objectId +
            ' references unknown payment ' +
            payload.paymentIntentId
        );
        continue;
      }
      if (ledgeredOriginals.contains(original.Id)) {
        markFinal(
          record,
          'Processed',
          'Refund ' +
            payload.objectId +
            ' already covered by the charge.refunded ledger'
        );
        continue;
      }
      knownRefundIds.add(payload.objectId);

      Payment__c refund = newPayment(record, payload, 'Refund');
      refund.Original_Payment__c = original.Id;
      refund.Invoice__c = original.Invoice__c;
      Decimal alreadyRefunded = refundedByOriginal.containsKey(original.Id)
        ? refundedByOriginal.get(original.Id)
        : 0;
      String reason;
      if (original.Status__c != 'Applied') {
        reason = REASON_ORIGINAL_NOT_APPLIED;
        refund.Status__c = 'Exception';
      } else if (payload.currencyCode != original.Currency_Code__c) {
        reason = REASON_CURRENCY_MISMATCH;
        refund.Status__c = 'Exception';
      } else if (alreadyRefunded + payload.amount > original.Amount__c) {
        reason = REASON_REFUND_EXCEEDS_PAYMENT;
        refund.Status__c = 'Exception';
      } else {
        refund.Status__c = 'Applied';
        refund.Match_Method__c = 'Refund_Link';
        refundedByOriginal.put(original.Id, alreadyRefunded + payload.amount);
      }
      refund.Exception_Reason__c = reason;
      toInsert.add(refund);
      insertedFor.add(record);
      reviewReasons.add(reason);
    }
    saveAndClassify(toInsert, insertedFor, reviewReasons);
  }

  /**
   * charge.refunded is Stripe's canonical refund signal: it carries the
   * charge's *cumulative* `amount_refunded`, not a per-refund delta. The
   * gateway reconciles by recording only the delta between that cumulative
   * total and the refunds already on file — replays and refund.created +
   * charge.refunded pairs for the same money collapse to zero and are marked
   * Processed, so retries never double-count.
   */
  private void applyChargeRefunds(
    List<Payment_Event__c> events,
    Map<Id, PaymentEventPayload> payloads
  ) {
    if (events.isEmpty()) {
      return;
    }
    Set<String> originalExternalIds = new Set<String>();
    for (Payment_Event__c record : events) {
      PaymentEventPayload payload = payloads.get(record.Id);
      if (String.isNotBlank(payload.paymentIntentId)) {
        originalExternalIds.add(payload.paymentIntentId);
      }
    }
    Map<String, Payment__c> originalsByExternalId = new Map<String, Payment__c>();
    for (
      Payment__c original : paymentSelector.selectByExternalIds(
        originalExternalIds
      )
    ) {
      originalsByExternalId.put(original.External_Payment_Id__c, original);
    }
    Map<Id, Decimal> refundedByOriginal = new Map<Id, Decimal>();
    Set<Id> originalIds = new Set<Id>();
    for (Payment__c original : originalsByExternalId.values()) {
      originalIds.add(original.Id);
    }
    for (
      AggregateResult row : paymentSelector.sumRefundsByOriginalPayment(
        originalIds
      )
    ) {
      refundedByOriginal.put(
        (Id) row.get('originalId'),
        (Decimal) row.get('total')
      );
    }

    List<Payment__c> toInsert = new List<Payment__c>();
    List<Payment_Event__c> insertedFor = new List<Payment_Event__c>();
    List<String> reviewReasons = new List<String>();
    for (Payment_Event__c record : events) {
      PaymentEventPayload payload = payloads.get(record.Id);
      if (String.isBlank(payload.paymentIntentId)) {
        markNeedsReview(record, REASON_MISSING_PAYMENT_REFERENCE);
        continue;
      }
      Payment__c original = originalsByExternalId.get(payload.paymentIntentId);
      if (original == null) {
        scheduleRetry(
          record,
          REASON_ORIGINAL_NOT_FOUND,
          'Charge refund ' +
            payload.objectId +
            ' references unknown payment ' +
            payload.paymentIntentId
        );
        continue;
      }

      Decimal alreadyRefunded = refundedByOriginal.containsKey(original.Id)
        ? refundedByOriginal.get(original.Id)
        : 0;
      Decimal delta = payload.amountRefunded - alreadyRefunded;
      if (delta == 0) {
        markFinal(
          record,
          'Processed',
          'Charge ' +
            payload.objectId +
            ' already reconciled to ' +
            payload.amountRefunded
        );
        continue;
      }
      if (delta < 0) {
        markNeedsReview(record, REASON_REFUND_BELOW_LEDGER);
        record.Last_Error__c =
          'Charge ' +
          payload.objectId +
          ' reports ' +
          payload.amountRefunded +
          ' refunded but the ledger already shows ' +
          alreadyRefunded;
        continue;
      }

      Payment__c refund = newPayment(record, payload, 'Refund');
      // The delta is keyed by event id so distinct charge.refunded events can
      // never collide on the charge-scoped synthetic id.
      refund.External_Payment_Id__c =
        payload.objectId +
        ':refunded:' +
        payload.eventId;
      refund.Amount__c = delta;
      refund.Original_Payment__c = original.Id;
      refund.Invoice__c = original.Invoice__c;
      String reason;
      if (original.Status__c != 'Applied') {
        reason = REASON_ORIGINAL_NOT_APPLIED;
        refund.Status__c = 'Exception';
      } else if (payload.currencyCode != original.Currency_Code__c) {
        reason = REASON_CURRENCY_MISMATCH;
        refund.Status__c = 'Exception';
      } else if (payload.amountRefunded > original.Amount__c) {
        reason = REASON_REFUND_EXCEEDS_PAYMENT;
        refund.Status__c = 'Exception';
      } else {
        refund.Status__c = 'Applied';
        refund.Match_Method__c = 'Charge_Refunded';
        refundedByOriginal.put(original.Id, alreadyRefunded + delta);
      }
      refund.Exception_Reason__c = reason;
      toInsert.add(refund);
      insertedFor.add(record);
      reviewReasons.add(reason);
    }
    saveAndClassify(toInsert, insertedFor, reviewReasons);
  }

  /**
   * A dispute is inherently an exception: it is recorded against the original
   * payment and always lands in Needs_Review for a human. Missing originals
   * retry like refunds, since dispute delivery can beat the payment event.
   */
  private void applyDisputes(
    List<Payment_Event__c> events,
    Map<Id, PaymentEventPayload> payloads
  ) {
    if (events.isEmpty()) {
      return;
    }
    Set<String> disputeIds = new Set<String>();
    Set<String> originalExternalIds = new Set<String>();
    for (Payment_Event__c record : events) {
      PaymentEventPayload payload = payloads.get(record.Id);
      disputeIds.add(payload.objectId);
      if (String.isNotBlank(payload.paymentIntentId)) {
        originalExternalIds.add(payload.paymentIntentId);
      }
    }
    Set<String> knownDisputeIds = externalIdsOf(
      paymentSelector.selectByExternalIds(disputeIds)
    );
    Map<String, Payment__c> originalsByExternalId = new Map<String, Payment__c>();
    for (
      Payment__c original : paymentSelector.selectByExternalIds(
        originalExternalIds
      )
    ) {
      originalsByExternalId.put(original.External_Payment_Id__c, original);
    }

    List<Payment__c> toInsert = new List<Payment__c>();
    List<Payment_Event__c> insertedFor = new List<Payment_Event__c>();
    List<String> reviewReasons = new List<String>();
    for (Payment_Event__c record : events) {
      PaymentEventPayload payload = payloads.get(record.Id);
      if (knownDisputeIds.contains(payload.objectId)) {
        markFinal(
          record,
          'Processed',
          'Dispute ' + payload.objectId + ' already recorded'
        );
        continue;
      }
      if (String.isBlank(payload.paymentIntentId)) {
        markNeedsReview(record, REASON_MISSING_PAYMENT_REFERENCE);
        continue;
      }
      Payment__c original = originalsByExternalId.get(payload.paymentIntentId);
      if (original == null) {
        scheduleRetry(
          record,
          REASON_ORIGINAL_NOT_FOUND,
          'Dispute ' +
            payload.objectId +
            ' references unknown payment ' +
            payload.paymentIntentId
        );
        continue;
      }
      knownDisputeIds.add(payload.objectId);

      Payment__c dispute = newPayment(record, payload, 'Dispute');
      dispute.Original_Payment__c = original.Id;
      dispute.Invoice__c = original.Invoice__c;
      dispute.Status__c = 'Exception';
      dispute.Exception_Reason__c = REASON_DISPUTE_OPENED;
      toInsert.add(dispute);
      insertedFor.add(record);
      reviewReasons.add(REASON_DISPUTE_OPENED);
    }
    saveAndClassify(toInsert, insertedFor, reviewReasons);
  }

  /**
   * `invoice.paid` is a reconciliation signal, not a payment: it creates no
   * Payment__c. It is Processed when the local invoice shows no remaining
   * balance, otherwise Needs_Review flags the drift for the ops queue.
   */
  /**
   * `payment_intent.payment_failed` moves no money, so it creates no
   * Payment__c — it is an ops signal. Every failure lands in Needs_Review
   * with the decline code/message and the invoice reference (if any) so the
   * desk can chase the customer for a new payment method.
   */
  private void applyPaymentFailures(
    List<Payment_Event__c> events,
    Map<Id, PaymentEventPayload> payloads
  ) {
    for (Payment_Event__c record : events) {
      PaymentEventPayload payload = payloads.get(record.Id);
      String detail = 'Payment ' + payload.objectId + ' failed';
      if (String.isNotBlank(payload.failureCode)) {
        detail += ' — ' + payload.failureCode;
      }
      if (String.isNotBlank(payload.failureMessage)) {
        detail += ' (' + payload.failureMessage + ')';
      }
      if (String.isNotBlank(payload.invoiceNumber)) {
        detail += '; invoice ' + payload.invoiceNumber;
      }
      record.Last_Error__c = detail;
      markNeedsReview(record, REASON_PAYMENT_FAILED);
    }
  }

  private void applyInvoicePaid(
    List<Payment_Event__c> events,
    Map<Id, PaymentEventPayload> payloads
  ) {
    if (events.isEmpty()) {
      return;
    }
    Set<String> invoiceNumbers = new Set<String>();
    for (Payment_Event__c record : events) {
      PaymentEventPayload payload = payloads.get(record.Id);
      if (String.isNotBlank(payload.invoiceNumber)) {
        invoiceNumbers.add(payload.invoiceNumber);
      }
    }
    Map<String, Invoice__c> invoicesByNumber = new Map<String, Invoice__c>();
    for (
      Invoice__c invoice : invoiceSelector.selectByInvoiceNumbers(
        invoiceNumbers
      )
    ) {
      invoicesByNumber.put(invoice.Invoice_Number__c.toUpperCase(), invoice);
    }

    for (Payment_Event__c record : events) {
      PaymentEventPayload payload = payloads.get(record.Id);
      if (String.isBlank(payload.invoiceNumber)) {
        markNeedsReview(record, REASON_MISSING_INVOICE_REFERENCE);
        continue;
      }
      Invoice__c invoice = invoicesByNumber.get(
        payload.invoiceNumber.toUpperCase()
      );
      if (invoice == null) {
        markNeedsReview(record, REASON_INVOICE_NOT_FOUND);
      } else if (
        !currencyMatches(invoice.Currency_Code__c, payload.currencyCode)
      ) {
        markNeedsReview(record, REASON_CURRENCY_MISMATCH);
      } else if (invoice.Balance_Due__c != null && invoice.Balance_Due__c > 0) {
        markNeedsReview(record, REASON_INVOICE_BALANCE_REMAINING);
      } else {
        markFinal(record, 'Processed', null);
      }
    }
  }

  /**
   * `charge.dispute.closed` resolves the Dispute Payment__c recorded by
   * `charge.dispute.created`. Won returns the dispute to Applied (funds kept);
   * lost keeps it in Exception with DISPUTE_LOST so a human can write it off.
   * A close that beats its own create retries like the other ordering races.
   */
  private void applyDisputeClosures(
    List<Payment_Event__c> events,
    Map<Id, PaymentEventPayload> payloads
  ) {
    if (events.isEmpty()) {
      return;
    }
    Set<String> disputeIds = new Set<String>();
    for (Payment_Event__c record : events) {
      disputeIds.add(payloads.get(record.Id).objectId);
    }
    Map<String, Payment__c> disputesByExternalId = new Map<String, Payment__c>();
    for (Payment__c dispute : paymentSelector.selectByExternalIds(disputeIds)) {
      disputesByExternalId.put(dispute.External_Payment_Id__c, dispute);
    }

    List<Payment__c> toUpdate = new List<Payment__c>();
    List<Payment_Event__c> updatedFor = new List<Payment_Event__c>();
    List<String> reviewReasons = new List<String>();
    Set<Id> queuedForUpdate = new Set<Id>();
    for (Payment_Event__c record : events) {
      PaymentEventPayload payload = payloads.get(record.Id);
      Payment__c dispute = disputesByExternalId.get(payload.objectId);
      if (dispute == null || dispute.Type__c != 'Dispute') {
        scheduleRetry(
          record,
          REASON_DISPUTE_NOT_FOUND,
          'Closed dispute ' + payload.objectId + ' was never recorded'
        );
        continue;
      }
      if (dispute.Status__c != 'Exception') {
        markFinal(
          record,
          'Processed',
          'Dispute ' + payload.objectId + ' already resolved'
        );
        continue;
      }
      String outcome = payload.disputeStatus == null
        ? ''
        : payload.disputeStatus.toLowerCase();
      if (queuedForUpdate.contains(dispute.Id)) {
        markFinal(
          record,
          'Processed',
          'Dispute ' + payload.objectId + ' already resolved in this batch'
        );
      } else if (outcome == 'won') {
        dispute.Status__c = 'Applied';
        dispute.Exception_Reason__c = REASON_DISPUTE_WON;
        toUpdate.add(dispute);
        queuedForUpdate.add(dispute.Id);
        updatedFor.add(record);
        reviewReasons.add(null);
      } else if (outcome == 'lost') {
        dispute.Exception_Reason__c = REASON_DISPUTE_LOST;
        toUpdate.add(dispute);
        queuedForUpdate.add(dispute.Id);
        updatedFor.add(record);
        reviewReasons.add(REASON_DISPUTE_LOST);
      } else {
        markNeedsReview(record, REASON_UNKNOWN_DISPUTE_STATUS);
      }
    }
    updateAndClassify(toUpdate, updatedFor, reviewReasons);
  }

  private void updateAndClassify(
    List<Payment__c> payments,
    List<Payment_Event__c> sourceEvents,
    List<String> reviewReasons
  ) {
    if (payments.isEmpty()) {
      return;
    }
    List<Database.SaveResult> results = Database.update(payments, false);
    for (Integer i = 0; i < results.size(); i++) {
      Payment_Event__c record = sourceEvents[i];
      Database.SaveResult result = results[i];
      if (result.isSuccess()) {
        if (reviewReasons[i] == null) {
          markFinal(record, 'Processed', null);
        } else {
          markNeedsReview(record, reviewReasons[i]);
        }
      } else {
        scheduleRetry(record, REASON_DML_ERROR, describe(result.getErrors()));
      }
    }
  }

  private void saveAndClassify(
    List<Payment__c> payments,
    List<Payment_Event__c> sourceEvents,
    List<String> reviewReasons
  ) {
    if (payments.isEmpty()) {
      return;
    }
    List<Database.SaveResult> results = Database.insert(payments, false);
    for (Integer i = 0; i < results.size(); i++) {
      Payment_Event__c record = sourceEvents[i];
      Database.SaveResult result = results[i];
      if (result.isSuccess()) {
        if (reviewReasons[i] == null) {
          markFinal(record, 'Processed', null);
        } else {
          markNeedsReview(record, reviewReasons[i]);
        }
      } else if (isDuplicate(result.getErrors())) {
        markFinal(
          record,
          'Processed',
          'Payment already recorded by a concurrent job'
        );
      } else {
        scheduleRetry(record, REASON_DML_ERROR, describe(result.getErrors()));
      }
    }
  }

  private static Payment__c newPayment(
    Payment_Event__c record,
    PaymentEventPayload payload,
    String type
  ) {
    return new Payment__c(
      External_Payment_Id__c = payload.objectId,
      Source_Event__c = record.Id,
      Type__c = type,
      Amount__c = payload.amount,
      Currency_Code__c = payload.currencyCode,
      Received_At__c = GatewayClock.now()
    );
  }

  private void scheduleRetry(
    Payment_Event__c record,
    String reason,
    String message
  ) {
    Integer attempts = record.Attempts__c.intValue();
    record.Exception_Reason__c = reason;
    record.Last_Error__c = message == null ? null : message.left(32768);
    if (RetryPolicy.isExhausted(attempts, maxAttempts)) {
      record.Status__c = 'Dead_Letter';
      record.Next_Attempt_At__c = null;
    } else {
      record.Status__c = 'Retry_Scheduled';
      record.Next_Attempt_At__c = RetryPolicy.nextAttemptAt(attempts);
    }
  }

  private static void markDeadLetter(
    Payment_Event__c record,
    String reason,
    String message
  ) {
    record.Status__c = 'Dead_Letter';
    record.Exception_Reason__c = reason;
    record.Last_Error__c = message;
    record.Next_Attempt_At__c = null;
  }

  private static void markNeedsReview(Payment_Event__c record, String reason) {
    record.Status__c = 'Needs_Review';
    record.Exception_Reason__c = reason;
    record.Next_Attempt_At__c = null;
    record.Processed_At__c = GatewayClock.now();
  }

  private static void markFinal(
    Payment_Event__c record,
    String status,
    String note
  ) {
    record.Status__c = status;
    record.Exception_Reason__c = null;
    record.Next_Attempt_At__c = null;
    record.Processed_At__c = GatewayClock.now();
    if (note != null) {
      record.Last_Error__c = note;
    }
  }

  private static Boolean currencyMatches(
    String invoiceCurrency,
    String paymentCurrency
  ) {
    return String.isNotBlank(invoiceCurrency) &&
      String.isNotBlank(paymentCurrency) &&
      invoiceCurrency.equalsIgnoreCase(paymentCurrency);
  }

  private static Set<String> externalIdsOf(List<Payment__c> payments) {
    Set<String> ids = new Set<String>();
    for (Payment__c payment : payments) {
      ids.add(payment.External_Payment_Id__c);
    }
    return ids;
  }

  private static Boolean isDuplicate(List<Database.Error> errors) {
    for (Database.Error error : errors) {
      if (error.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
        return true;
      }
    }
    return false;
  }

  private static String describe(List<Database.Error> errors) {
    List<String> messages = new List<String>();
    for (Database.Error error : errors) {
      messages.add(error.getStatusCode() + ': ' + error.getMessage());
    }
    return String.join(messages, '; ');
  }
}
