/**
 * SOQL for Payment__c, including the aggregate that drives invoice roll-ups.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public inherited sharing class PaymentSelector {
  public List<Payment__c> selectByExternalIds(Set<String> externalIds) {
    if (externalIds == null || externalIds.isEmpty()) {
      return new List<Payment__c>();
    }
    return [
      SELECT
        Id,
        External_Payment_Id__c,
        Invoice__c,
        Type__c,
        Amount__c,
        Currency_Code__c,
        Status__c,
        Source_Event__c
      FROM Payment__c
      WHERE External_Payment_Id__c IN :externalIds
    ];
  }

  public List<AggregateResult> sumAppliedByInvoiceAndType(Set<Id> invoiceIds) {
    if (invoiceIds == null || invoiceIds.isEmpty()) {
      return new List<AggregateResult>();
    }
    return [
      SELECT Invoice__c invoiceId, Type__c paymentType, SUM(Amount__c) total
      FROM Payment__c
      WHERE
        Invoice__c IN :invoiceIds
        AND Status__c = 'Applied'
        AND Type__c IN ('Payment', 'Refund')
      GROUP BY Invoice__c, Type__c
    ];
  }

  /** Originals whose refunds were already reconciled by charge.refunded deltas. */
  public Set<Id> selectChargeLedgeredOriginalIds(Set<Id> originalPaymentIds) {
    Set<Id> ids = new Set<Id>();
    for (Payment__c refund : [
      SELECT Original_Payment__c
      FROM Payment__c
      WHERE
        Original_Payment__c IN :originalPaymentIds
        AND Type__c = 'Refund'
        AND Status__c = 'Applied'
        AND External_Payment_Id__c LIKE '%:refunded:%'
    ]) {
      ids.add(refund.Original_Payment__c);
    }
    return ids;
  }

  public List<AggregateResult> sumRefundsByOriginalPayment(
    Set<Id> originalPaymentIds
  ) {
    if (originalPaymentIds == null || originalPaymentIds.isEmpty()) {
      return new List<AggregateResult>();
    }
    return [
      SELECT Original_Payment__c originalId, SUM(Amount__c) total
      FROM Payment__c
      WHERE
        Original_Payment__c IN :originalPaymentIds
        AND Type__c = 'Refund'
        AND Status__c = 'Applied'
      GROUP BY Original_Payment__c
    ];
  }

  public List<Payment__c> selectBySourceEventAsUser(Id eventId) {
    return [
      SELECT Id, Invoice__c, Type__c, Amount__c, Currency_Code__c, Status__c
      FROM Payment__c
      WHERE Source_Event__c = :eventId
      WITH USER_MODE
      ORDER BY CreatedDate
    ];
  }
}
