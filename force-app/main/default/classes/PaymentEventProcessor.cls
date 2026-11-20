/**
 * Queueable that processes due Payment_Event__c records in batches and
 * schedules its own follow-up for backlog or near-term retries.
 * Runs in system mode: it is an integration job, not a user action.
 */
public without sharing class PaymentEventProcessor implements Queueable {
  public static final Integer BATCH_SIZE = 200;

  public void execute(QueueableContext context) {
    run();
  }

  public void run() {
    PaymentEventSelector selector = new PaymentEventSelector();
    List<Payment_Event__c> due = selector.selectDueForProcessing(BATCH_SIZE);
    if (!due.isEmpty()) {
      new PaymentEventService().process(due);
    }
    scheduleFollowUp(selector);
  }

  private void scheduleFollowUp(PaymentEventSelector selector) {
    if (selector.countDueForProcessing() > 0) {
      AsyncJobs.enqueue(new PaymentEventProcessor(), 0);
      return;
    }
    if (
      GatewaySettings.billingSyncEnabled() &&
      !new InvoiceSelector().selectDueForBillingSync(1).isEmpty()
    ) {
      AsyncJobs.enqueue(new BillingSyncQueueable(), 0);
      return;
    }
    List<Payment_Event__c> nextRetry = selector.selectNextScheduledRetry();
    if (nextRetry.isEmpty()) {
      return;
    }
    Integer delay = minutesUntil(nextRetry[0].Next_Attempt_At__c);
    if (delay <= AsyncJobs.MAX_DELAY_MINUTES) {
      AsyncJobs.enqueue(new PaymentEventProcessor(), delay);
    }
    // Longer delays are picked up by GatewaySweeper.
  }

  @TestVisible
  private static Integer minutesUntil(Datetime target) {
    Long millis = target.getTime() - GatewayClock.now().getTime();
    Decimal minutes = Decimal.valueOf(millis) / 60000;
    return Math.max(1, minutes.round(System.RoundingMode.CEILING).intValue());
  }
}
