/**
 * Apex API for the reconciliation console LWC. Runs with sharing and uses
 * user-mode queries/DML so the operator's object and field access applies.
 */
public with sharing class ReconciliationController {
  public static final Set<String> QUEUE_STATUSES = new Set<String>{
    'Needs_Review',
    'Retry_Scheduled',
    'Dead_Letter'
  };
  public static final Set<String> RETRYABLE_STATUSES = new Set<String>{
    'Retry_Scheduled',
    'Dead_Letter'
  };
  private static final Set<String> MATCHABLE_PAYMENT_STATUSES = new Set<String>{
    'Unmatched',
    'Exception'
  };
  private static final Integer QUEUE_LIMIT = 200;
  private static final Integer SEARCH_LIMIT = 20;
  private static final Integer SUGGESTION_LIMIT = 5;
  private static final Integer SUGGESTION_POOL = 100;

  public class EventDetail {
    @AuraEnabled
    public Payment_Event__c event;
    @AuraEnabled
    public String formattedPayload;
    @AuraEnabled
    public List<Payment__c> payments;
    @AuraEnabled
    public Boolean canRetry;
    @AuraEnabled
    public Boolean canMatch;
  }

  @AuraEnabled(cacheable=true)
  public static List<Payment_Event__c> getQueue(List<String> statuses) {
    Set<String> requested = new Set<String>();
    if (statuses != null) {
      requested.addAll(statuses);
    }
    requested.retainAll(QUEUE_STATUSES);
    if (requested.isEmpty()) {
      requested.addAll(QUEUE_STATUSES);
    }
    return new PaymentEventSelector().selectQueueAsUser(requested, QUEUE_LIMIT);
  }

  // Not cacheable: the console must see fresh state after retry/match.
  @AuraEnabled
  public static EventDetail getEventDetail(Id eventId) {
    Payment_Event__c record = loadEvent(eventId);
    EventDetail detail = new EventDetail();
    detail.event = record;
    detail.formattedPayload = prettyPrint(record.Payload__c);
    detail.payments = new PaymentSelector().selectBySourceEventAsUser(eventId);
    detail.canRetry = RETRYABLE_STATUSES.contains(record.Status__c);
    detail.canMatch =
      record.Status__c == 'Needs_Review' &&
      findMatchablePayment(detail.payments) != null;
    return detail;
  }

  /**
   * Open invoices in the payment's currency, ranked by closeness of
   * Balance_Due__c to the payment amount (exact matches first). Returns an
   * empty list when the event has no matchable payment.
   */
  @AuraEnabled
  public static List<Invoice__c> suggestInvoices(Id eventId) {
    loadEvent(eventId); // 404s for missing or inaccessible events
    Payment__c payment = findMatchablePayment(
      new PaymentSelector().selectBySourceEventAsUser(eventId)
    );
    if (
      payment == null ||
      payment.Amount__c == null ||
      String.isBlank(payment.Currency_Code__c)
    ) {
      return new List<Invoice__c>();
    }
    List<Invoice__c> candidates = new InvoiceSelector()
      .selectOpenByCurrencyAsUser(payment.Currency_Code__c, SUGGESTION_POOL);
    List<InvoiceByBalanceDistance> ranked = new List<InvoiceByBalanceDistance>();
    for (Invoice__c invoice : candidates) {
      ranked.add(new InvoiceByBalanceDistance(invoice, payment.Amount__c));
    }
    ranked.sort();
    List<Invoice__c> suggestions = new List<Invoice__c>();
    for (Integer i = 0; i < Math.min(SUGGESTION_LIMIT, ranked.size()); i++) {
      suggestions.add(ranked[i].invoice);
    }
    return suggestions;
  }

  @AuraEnabled(cacheable=true)
  public static List<Invoice__c> searchInvoices(String term) {
    if (term == null || term.trim().length() < 2) {
      return new List<Invoice__c>();
    }
    return new InvoiceSelector().searchOpenInvoicesAsUser(term, SEARCH_LIMIT);
  }

  @AuraEnabled
  public static void retryEvent(Id eventId) {
    Payment_Event__c record = loadEvent(eventId);
    if (!RETRYABLE_STATUSES.contains(record.Status__c)) {
      throw handled(
        'Only events in Retry_Scheduled or Dead_Letter can be retried.'
      );
    }
    Payment_Event__c reset = new Payment_Event__c(
      Id = record.Id,
      Status__c = 'Received',
      Attempts__c = 0,
      Next_Attempt_At__c = null,
      Exception_Reason__c = null
    );
    Database.update(reset, AccessLevel.USER_MODE);
  }

  @AuraEnabled
  public static void matchToInvoice(Id eventId, Id invoiceId) {
    Payment_Event__c record = loadEvent(eventId);
    if (record.Status__c != 'Needs_Review') {
      throw handled('Only events in Needs_Review can be matched manually.');
    }
    Payment__c payment = findMatchablePayment(
      new PaymentSelector().selectBySourceEventAsUser(eventId)
    );
    if (payment == null) {
      throw handled('This event has no unmatched payment to apply.');
    }
    List<Invoice__c> invoices = new InvoiceSelector()
      .selectByIdAsUser(invoiceId);
    if (invoices.isEmpty()) {
      throw handled('Invoice not found or not accessible.');
    }
    Invoice__c invoice = invoices[0];
    if (!InvoiceSelector.PAYABLE_STATUSES.contains(invoice.Status__c)) {
      throw handled(
        'Invoice ' + invoice.Invoice_Number__c + ' is not open for payment.'
      );
    }
    if (
      String.isBlank(invoice.Currency_Code__c) ||
      !invoice.Currency_Code__c.equalsIgnoreCase(payment.Currency_Code__c)
    ) {
      throw handled(
        'Currency mismatch: payment is ' +
          payment.Currency_Code__c +
          ', invoice is ' +
          invoice.Currency_Code__c +
          '.'
      );
    }
    Database.update(
      new Payment__c(
        Id = payment.Id,
        Invoice__c = invoice.Id,
        Status__c = 'Applied',
        Match_Method__c = 'Manual',
        Exception_Reason__c = null
      ),
      AccessLevel.USER_MODE
    );
    Database.update(
      new Payment_Event__c(
        Id = record.Id,
        Status__c = 'Resolved',
        Exception_Reason__c = null,
        Processed_At__c = GatewayClock.now()
      ),
      AccessLevel.USER_MODE
    );
  }

  private static Payment_Event__c loadEvent(Id eventId) {
    List<Payment_Event__c> records = new PaymentEventSelector()
      .selectByIdAsUser(eventId);
    if (records.isEmpty()) {
      throw handled('Event not found or not accessible.');
    }
    return records[0];
  }

  private static Payment__c findMatchablePayment(List<Payment__c> payments) {
    for (Payment__c payment : payments) {
      if (
        payment.Type__c == 'Payment' &&
        MATCHABLE_PAYMENT_STATUSES.contains(payment.Status__c)
      ) {
        return payment;
      }
    }
    return null;
  }

  @TestVisible
  private static String prettyPrint(String payload) {
    if (String.isBlank(payload)) {
      return payload;
    }
    try {
      return JSON.serializePretty(JSON.deserializeUntyped(payload));
    } catch (JSONException e) {
      return payload;
    }
  }

  /** Sorts candidates by |Balance_Due__c - payment amount|, blanks last. */
  private class InvoiceByBalanceDistance implements Comparable {
    public Invoice__c invoice;
    private Decimal distance;

    InvoiceByBalanceDistance(Invoice__c invoice, Decimal amount) {
      this.invoice = invoice;
      this.distance = invoice.Balance_Due__c == null
        ? null
        : Math.abs(invoice.Balance_Due__c - amount);
    }

    public Integer compareTo(Object other) {
      Decimal mine = distance;
      Decimal theirs = ((InvoiceByBalanceDistance) other).distance;
      if (mine == null && theirs == null) {
        return 0;
      }
      if (mine == null) {
        return 1;
      }
      if (theirs == null) {
        return -1;
      }
      return mine == theirs ? 0 : (mine < theirs ? -1 : 1);
    }
  }

  private static AuraHandledException handled(String message) {
    AuraHandledException error = new AuraHandledException(message);
    error.setMessage(message);
    return error;
  }
}
