/**
 * Guarded Queueable enqueueing. Async contexts may enqueue only one child
 * job, and tests cannot chain Queueables, so callers must tolerate "false";
 * GatewaySweeper re-enqueues any work that is still due.
 */
public inherited sharing class AsyncJobs {
  public static final Integer MAX_DELAY_MINUTES = 10;

  @TestVisible
  private static List<String> requestedJobs = new List<String>();
  @TestVisible
  private static List<String> enqueuedJobs = new List<String>();

  public static Boolean enqueue(Queueable job, Integer delayMinutes) {
    String jobName = String.valueOf(job).substringBefore(':');
    requestedJobs.add(jobName);
    if (!canEnqueue()) {
      return false;
    }
    Integer delay = delayMinutes == null
      ? 0
      : Math.max(0, Math.min(delayMinutes, MAX_DELAY_MINUTES));
    if (delay > 0) {
      System.enqueueJob(job, delay);
    } else {
      System.enqueueJob(job);
    }
    enqueuedJobs.add(jobName);
    return true;
  }

  public static Boolean canEnqueue() {
    Boolean inAsyncContext =
      System.isQueueable() ||
      System.isBatch() ||
      System.isFuture();
    if (Test.isRunningTest() && inAsyncContext) {
      return false;
    }
    return Limits.getQueueableJobs() < Limits.getLimitQueueableJobs();
  }

  @TestVisible
  private static Boolean wasRequested(String jobName) {
    return requestedJobs.contains(jobName);
  }
}
