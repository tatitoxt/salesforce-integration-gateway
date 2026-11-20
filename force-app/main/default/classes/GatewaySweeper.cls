/**
 * Scheduled safety net: re-enqueues processing for due events and invoices
 * whose retry is further out than a delayed Queueable allows, or whose
 * follow-up could not be chained.
 */
public without sharing class GatewaySweeper implements Schedulable {
  public static final String JOB_NAME_PREFIX = 'Integration Gateway Sweeper';

  public void execute(SchedulableContext context) {
    sweep();
  }

  public void sweep() {
    if (new PaymentEventSelector().countDueForProcessing() > 0) {
      AsyncJobs.enqueue(new PaymentEventProcessor(), 0);
    }
    if (
      GatewaySettings.billingSyncEnabled() &&
      !new InvoiceSelector().selectDueForBillingSync(1).isEmpty()
    ) {
      AsyncJobs.enqueue(new BillingSyncQueueable(), 0);
    }
  }

  /** Schedules the sweeper every 15 minutes (four cron jobs). */
  @SuppressWarnings('PMD.OperationWithLimitsInLoop')
  public static List<Id> scheduleEvery15Minutes() {
    List<Id> jobIds = new List<Id>();
    for (Integer minute = 0; minute < 60; minute += 15) {
      jobIds.add(
        System.schedule(
          JOB_NAME_PREFIX + ' :' + String.valueOf(minute).leftPad(2, '0'),
          '0 ' + minute + ' * * * ?',
          new GatewaySweeper()
        )
      );
    }
    return jobIds;
  }
}
