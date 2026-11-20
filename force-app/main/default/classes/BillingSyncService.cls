/**
 * Pushes invoice payment status to the billing platform and decides, per
 * response, between Synced, Retry_Scheduled (429/5xx/408/timeouts) and Failed.
 * Returns the invoice updates so callers perform DML after all callouts.
 */
public inherited sharing class BillingSyncService {
  private final BillingPlatformClient client;

  public BillingSyncService(BillingPlatformClient client) {
    this.client = client;
  }

  public List<Invoice__c> sync(List<Invoice__c> invoices) {
    Integer maxAttempts = GatewaySettings.maxBillingAttempts();
    List<Invoice__c> updates = new List<Invoice__c>();
    for (Invoice__c invoice : invoices) {
      if (Limits.getCallouts() >= Limits.getLimitCallouts()) {
        break;
      }
      Integer attempts =
        (invoice.Billing_Sync_Attempts__c == null
          ? 0
          : invoice.Billing_Sync_Attempts__c.intValue()) + 1;
      Invoice__c result = new Invoice__c(
        Id = invoice.Id,
        Billing_Sync_Attempts__c = attempts
      );
      try {
        HttpResponse response = client.pushInvoiceStatus(invoice);
        Integer statusCode = response.getStatusCode();
        if (statusCode >= 200 && statusCode < 300) {
          markSynced(result, response.getBody());
        } else if (RetryPolicy.isRetryableHttpStatus(statusCode)) {
          markRetry(result, attempts, maxAttempts, 'HTTP ' + statusCode);
        } else {
          markFailed(
            result,
            'HTTP ' + statusCode + ': ' + abbreviate(response.getBody())
          );
        }
      } catch (CalloutException e) {
        markRetry(
          result,
          attempts,
          maxAttempts,
          'Callout error: ' + e.getMessage()
        );
      }
      updates.add(result);
    }
    return updates;
  }

  private static void markSynced(Invoice__c result, String body) {
    result.Billing_Sync_Status__c = 'Synced';
    result.Billing_Last_Synced_At__c = GatewayClock.now();
    result.Billing_Next_Attempt_At__c = null;
    result.Billing_Last_Error__c = null;
    String externalId = parseExternalId(body);
    if (externalId != null) {
      result.Billing_External_Id__c = externalId;
    }
  }

  private static void markRetry(
    Invoice__c result,
    Integer attempts,
    Integer maxAttempts,
    String message
  ) {
    result.Billing_Last_Error__c = abbreviate(message);
    if (RetryPolicy.isExhausted(attempts, maxAttempts)) {
      result.Billing_Sync_Status__c = 'Failed';
      result.Billing_Next_Attempt_At__c = null;
    } else {
      result.Billing_Sync_Status__c = 'Retry_Scheduled';
      result.Billing_Next_Attempt_At__c = RetryPolicy.nextAttemptAt(attempts);
    }
  }

  private static void markFailed(Invoice__c result, String message) {
    result.Billing_Sync_Status__c = 'Failed';
    result.Billing_Next_Attempt_At__c = null;
    result.Billing_Last_Error__c = abbreviate(message);
  }

  @TestVisible
  private static String parseExternalId(String body) {
    if (String.isBlank(body)) {
      return null;
    }
    try {
      Object parsed = JSON.deserializeUntyped(body);
      if (parsed instanceof Map<String, Object>) {
        Object id = ((Map<String, Object>) parsed).get('id');
        return id == null ? null : String.valueOf(id).left(64);
      }
    } catch (JSONException e) {
      return null;
    }
    return null;
  }

  private static String abbreviate(String value) {
    return value == null ? null : value.abbreviate(1000);
  }
}
