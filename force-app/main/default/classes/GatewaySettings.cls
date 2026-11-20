/**
 * Reads Payment_Gateway_Settings__c (protected hierarchy custom setting).
 * No record ships in source: the signing secret is configured per org.
 */
public inherited sharing class GatewaySettings {
  public static final Integer DEFAULT_TOLERANCE_SECONDS = 300;
  public static final Integer DEFAULT_MAX_ATTEMPTS = 5;

  @TestVisible
  private static Payment_Gateway_Settings__c cached;

  public static Payment_Gateway_Settings__c get() {
    if (cached == null) {
      cached = Payment_Gateway_Settings__c.getOrgDefaults();
    }
    return cached;
  }

  public static String signingSecret() {
    return get().Webhook_Signing_Secret__c;
  }

  public static Integer toleranceSeconds() {
    return positiveOrDefault(
      get().Signature_Tolerance_Seconds__c,
      DEFAULT_TOLERANCE_SECONDS
    );
  }

  public static Integer maxEventAttempts() {
    return positiveOrDefault(get().Max_Event_Attempts__c, DEFAULT_MAX_ATTEMPTS);
  }

  public static Integer maxBillingAttempts() {
    return positiveOrDefault(
      get().Max_Billing_Attempts__c,
      DEFAULT_MAX_ATTEMPTS
    );
  }

  public static Boolean billingSyncEnabled() {
    return get().Billing_Sync_Enabled__c == true;
  }

  @TestVisible
  private static void reset() {
    cached = null;
  }

  private static Integer positiveOrDefault(Decimal value, Integer fallback) {
    return (value == null || value <= 0) ? fallback : value.intValue();
  }
}
