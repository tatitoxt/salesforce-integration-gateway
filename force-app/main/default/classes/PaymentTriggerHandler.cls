/**
 * Keeps invoice roll-ups consistent with Payment__c inserts, updates,
 * deletes and undeletes.
 */
public inherited sharing class PaymentTriggerHandler extends TriggerHandler {
  protected override String getHandlerName() {
    return 'PaymentTriggerHandler';
  }

  protected override void afterInsert(List<SObject> records) {
    recalculate(invoiceIdsOf(records));
  }

  protected override void afterUpdate(
    List<SObject> records,
    Map<Id, SObject> oldRecordsById
  ) {
    Set<Id> invoiceIds = new Set<Id>();
    for (Payment__c payment : (List<Payment__c>) records) {
      Payment__c old = (Payment__c) oldRecordsById.get(payment.Id);
      if (
        payment.Invoice__c != old.Invoice__c ||
        payment.Amount__c != old.Amount__c ||
        payment.Status__c != old.Status__c ||
        payment.Type__c != old.Type__c
      ) {
        invoiceIds.add(payment.Invoice__c);
        invoiceIds.add(old.Invoice__c);
      }
    }
    recalculate(invoiceIds);
  }

  protected override void afterDelete(Map<Id, SObject> oldRecordsById) {
    recalculate(invoiceIdsOf(oldRecordsById.values()));
  }

  protected override void afterUndelete(List<SObject> records) {
    recalculate(invoiceIdsOf(records));
  }

  private static Set<Id> invoiceIdsOf(List<SObject> records) {
    Set<Id> invoiceIds = new Set<Id>();
    for (Payment__c payment : (List<Payment__c>) records) {
      invoiceIds.add(payment.Invoice__c);
    }
    return invoiceIds;
  }

  private static void recalculate(Set<Id> invoiceIds) {
    new InvoiceRollupService().recalculate(invoiceIds);
  }
}
