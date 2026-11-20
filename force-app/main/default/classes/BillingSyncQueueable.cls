/**
 * Queueable (with callouts) that syncs due invoices to the billing platform.
 * All callouts happen before the single DML statement.
 */
public without sharing class BillingSyncQueueable implements Queueable, Database.AllowsCallouts {
  public static final Integer BATCH_SIZE = 50;

  public void execute(QueueableContext context) {
    run();
  }

  public void run() {
    InvoiceSelector selector = new InvoiceSelector();
    List<Invoice__c> due = selector.selectDueForBillingSync(BATCH_SIZE);
    if (due.isEmpty()) {
      return;
    }
    List<Invoice__c> updates = new BillingSyncService(
        new BillingPlatformClient()
      )
      .sync(due);
    update updates;
    if (!selector.selectDueForBillingSync(1).isEmpty()) {
      AsyncJobs.enqueue(new BillingSyncQueueable(), 0);
    }
  }
}
