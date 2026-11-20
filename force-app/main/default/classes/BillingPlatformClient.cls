/**
 * Outbound adapter for the billing platform. The endpoint and credentials
 * come from the Billing_Platform Named Credential; nothing is stored in code.
 */
public inherited sharing class BillingPlatformClient {
  public static final String NAMED_CREDENTIAL = 'callout:Billing_Platform';
  public static final Integer TIMEOUT_MILLIS = 10000;

  public virtual class BillingException extends Exception {
  }

  public HttpResponse pushInvoiceStatus(Invoice__c invoice) {
    HttpRequest request = new HttpRequest();
    request.setEndpoint(
      NAMED_CREDENTIAL +
        '/v1/invoices/' +
        EncodingUtil.urlEncode(invoice.Invoice_Number__c, 'UTF-8') +
        '/payment-status'
    );
    request.setMethod('PUT');
    request.setTimeout(TIMEOUT_MILLIS);
    request.setHeader('Content-Type', 'application/json');
    request.setHeader('Idempotency-Key', idempotencyKey(invoice));
    request.setBody(JSON.serialize(buildBody(invoice)));
    return new Http().send(request);
  }

  @TestVisible
  private static String idempotencyKey(Invoice__c invoice) {
    return invoice.Id +
      ':' +
      String.valueOf(invoice.Amount_Paid__c) +
      ':' +
      invoice.Status__c;
  }

  @TestVisible
  private static Map<String, Object> buildBody(Invoice__c invoice) {
    return new Map<String, Object>{
      'invoice_number' => invoice.Invoice_Number__c,
      'external_id' => invoice.Billing_External_Id__c,
      'customer_reference' => invoice.Customer_Reference__c,
      'currency' => invoice.Currency_Code__c,
      'total_amount' => invoice.Total_Amount__c,
      'amount_paid' => invoice.Amount_Paid__c,
      'amount_refunded' => invoice.Amount_Refunded__c,
      'balance_due' => invoice.Balance_Due__c,
      'status' => invoice.Status__c
    };
  }
}
