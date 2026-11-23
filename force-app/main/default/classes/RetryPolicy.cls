/**
 * Exponential backoff shared by event processing and billing sync:
 * 2^attempts minutes, capped at MAX_BACKOFF_MINUTES.
 */
public inherited sharing class RetryPolicy {
  public static final Integer MAX_BACKOFF_MINUTES = 60;

  public static Integer backoffMinutes(Integer attempts) {
    Integer safeAttempts = attempts == null || attempts < 1 ? 1 : attempts;
    Integer minutes = 1;
    for (
      Integer i = 0; i < safeAttempts && minutes < MAX_BACKOFF_MINUTES; i++
    ) {
      minutes *= 2;
    }
    return Math.min(MAX_BACKOFF_MINUTES, minutes);
  }

  public static Datetime nextAttemptAt(Integer attempts) {
    return GatewayClock.now().addMinutes(backoffMinutes(attempts));
  }

  public static Boolean isExhausted(Integer attempts, Integer maxAttempts) {
    return attempts >= maxAttempts;
  }

  public static Boolean isRetryableHttpStatus(Integer statusCode) {
    return statusCode == 408 || statusCode == 429 || statusCode >= 500;
  }
}
