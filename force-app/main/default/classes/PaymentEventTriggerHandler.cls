/**
 * Starts asynchronous processing when events become due (inserted or reset
 * to Received by a retry).
 */
public inherited sharing class PaymentEventTriggerHandler extends TriggerHandler {
  protected override String getHandlerName() {
    return 'PaymentEventTriggerHandler';
  }

  protected override void afterInsert(List<SObject> records) {
    for (Payment_Event__c record : (List<Payment_Event__c>) records) {
      if (record.Status__c == 'Received') {
        AsyncJobs.enqueue(new PaymentEventProcessor(), 0);
        return;
      }
    }
  }

  protected override void afterUpdate(
    List<SObject> records,
    Map<Id, SObject> oldRecordsById
  ) {
    for (Payment_Event__c record : (List<Payment_Event__c>) records) {
      Payment_Event__c old = (Payment_Event__c) oldRecordsById.get(record.Id);
      if (record.Status__c == 'Received' && old.Status__c != 'Received') {
        AsyncJobs.enqueue(new PaymentEventProcessor(), 0);
        return;
      }
    }
  }
}
