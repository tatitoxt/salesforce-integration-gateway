/**
 * Transaction Finalizer for PaymentEventProcessor. It is the only code that
 * still runs when the parent job dies on a governor limit — a catch block
 * can never enqueue the retry in that case — so it is where crash recovery
 * lives. On UNHANDLED_EXCEPTION it re-enqueues the processor immediately
 * instead of waiting up to 15 minutes for GatewaySweeper, carrying a crash
 * depth that gives up after MAX_CRASH_RETRIES consecutive failures and
 * hands the job back to the sweeper.
 * Nothing runs on success: the follow-up chain is decided inside execute().
 */
public without sharing class PaymentEventRetryFinalizer implements System.Finalizer {
  private final Integer crashDepth;

  public PaymentEventRetryFinalizer(Integer crashDepth) {
    this.crashDepth = crashDepth == null ? 0 : crashDepth;
  }

  public void execute(FinalizerContext context) {
    if (context.getResult() == System.ParentJobResult.UNHANDLED_EXCEPTION) {
      handleCrash(context.getException());
    }
  }

  /**
   * Returns whether a retry was actually enqueued so tests can assert the
   * decision without inspecting the async queue.
   */
  @TestVisible
  private Boolean handleCrash(Exception cause) {
    System.debug(
      LoggingLevel.ERROR,
      'PaymentEventProcessor crashed (depth ' +
        crashDepth +
        '): ' +
        (cause == null
          ? 'unknown'
          : cause.getTypeName() + ': ' + cause.getMessage())
    );
    if (crashDepth >= PaymentEventProcessor.MAX_CRASH_RETRIES) {
      return false;
    }
    return AsyncJobs.enqueue(new PaymentEventProcessor(crashDepth + 1), 0);
  }
}
