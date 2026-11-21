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
  public static final String REASON_INVOICE_BALANCE_REMAINING = 'INVOICE_BALANCE_REMAINING';
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
    List<Payment_Event__c> invoicePaidEvents = new List<Payment_Event__c>();
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
      } else if (payload.isInvoicePaid()) {
        invoicePaidEvents.add(record);
      } else {
        markFinal(record, 'Ignored', null);
      }
    }

    Savepoint beforeApply = Database.setSavepoint();
    try {
      applyPayments(paymentEvents, payloads);
      applyRefunds(refundEvents, payloads);
      applyDisputes(disputeEvents, payloads);
      applyInvoicePaid(invoicePaidEvents, payloads);
    } catch (Exception e) {
      Database.rollback(beforeApply);
      List<Payment_Event__c> affected = new List<Payment_Event__c>(
        paymentEvents
      );
      affected.addAll(refundEvents);
      affected.addAll(disputeEvents);
      affected.addAll(invoicePaidEvents);
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
      Invoice__c exactAmountInvoice = amountCandidates != null &&
        amountCandidates.size() == 1
        ? amountCandidates[0]
        : null;
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
      } else if (invoice.Balance_Due__c != null && invoice.Balance_Due__c > 0) {
        markNeedsReview(record, REASON_INVOICE_BALANCE_REMAINING);
      } else {
        markFinal(record, 'Processed', null);
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
