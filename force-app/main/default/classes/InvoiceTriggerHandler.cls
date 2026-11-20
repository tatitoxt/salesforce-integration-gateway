/**
 * Flags invoices for billing sync when their payment position changes and,
 * outside of other async jobs, starts the sync immediately.
 */
public inherited sharing class InvoiceTriggerHandler extends TriggerHandler {
  protected override String getHandlerName() {
    return 'InvoiceTriggerHandler';
  }

  protected override void beforeUpdate(
    List<SObject> records,
    Map<Id, SObject> oldRecordsById
  ) {
    if (!GatewaySettings.billingSyncEnabled()) {
      return;
    }
    for (Invoice__c invoice : (List<Invoice__c>) records) {
      Invoice__c old = (Invoice__c) oldRecordsById.get(invoice.Id);
      if (paymentPositionChanged(invoice, old)) {
        invoice.Billing_Sync_Status__c = 'Pending';
        invoice.Billing_Sync_Attempts__c = 0;
        invoice.Billing_Next_Attempt_At__c = null;
        invoice.Billing_Last_Error__c = null;
      }
    }
  }

  protected override void afterUpdate(
    List<SObject> records,
    Map<Id, SObject> oldRecordsById
  ) {
    // Inside a Queueable only one child job is allowed; the event processor
    // chains billing sync itself, so only start it here for synchronous edits.
    if (System.isQueueable() || System.isBatch() || System.isFuture()) {
      return;
    }
    for (Invoice__c invoice : (List<Invoice__c>) records) {
      Invoice__c old = (Invoice__c) oldRecordsById.get(invoice.Id);
      if (
        invoice.Billing_Sync_Status__c == 'Pending' &&
        paymentPositionChanged(invoice, old)
      ) {
        AsyncJobs.enqueue(new BillingSyncQueueable(), 0);
        return;
      }
    }
  }

  private static Boolean paymentPositionChanged(
    Invoice__c invoice,
    Invoice__c old
  ) {
    return invoice.Amount_Paid__c != old.Amount_Paid__c ||
      invoice.Amount_Refunded__c != old.Amount_Refunded__c ||
      invoice.Status__c != old.Status__c;
  }
}
