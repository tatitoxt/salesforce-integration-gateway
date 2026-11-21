/**
 * Queueable that processes due Payment_Event__c records in batches and
 * schedules its own follow-up for backlog or near-term retries.
 * Runs in system mode: it is an integration job, not a user action.
 */
public without sharing class PaymentEventProcessor implements Queueable {
  // Bounded by heap, not row count: 50 x 64 KB payloads stay well below the
  // 12 MB async heap limit including parsed JSON.
  public static final Integer BATCH_SIZE = 50;
  /**
   * Consecutive unhandled crashes that PaymentEventRetryFinalizer retries
   * immediately before the scheduled sweeper takes over.
   */
  public static final Integer MAX_CRASH_RETRIES = 3;

  private final Integer crashDepth;

  public PaymentEventProcessor() {
    this(0);
  }

  public PaymentEventProcessor(Integer crashDepth) {
    this.crashDepth = crashDepth == null ? 0 : crashDepth;
  }

  public void execute(QueueableContext context) {
    // A finalizer still runs when this job dies on a governor limit, where a
    // catch block could never enqueue the retry.
    System.attachFinalizer(new PaymentEventRetryFinalizer(crashDepth));
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
