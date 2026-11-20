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

  private static AuraHandledException handled(String message) {
    AuraHandledException error = new AuraHandledException(message);
    error.setMessage(message);
    return error;
  }
}
