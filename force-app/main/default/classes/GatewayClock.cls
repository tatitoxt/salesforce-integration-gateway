/**
 * Single source of "now" so tests can pin time for signature tolerance and
 * retry scheduling.
 */
public inherited sharing class GatewayClock {
  @TestVisible
  private static Datetime fixedNow;

  public static Datetime now() {
    return fixedNow != null ? fixedNow : Datetime.now();
  }

  public static Long nowUnixSeconds() {
    return now().getTime() / 1000;
  }
}
