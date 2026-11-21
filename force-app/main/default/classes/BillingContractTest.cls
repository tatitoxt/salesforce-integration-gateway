/**
 * Contract tests for the billing platform: they pin the exact wire format the
 * external API depends on (endpoint shape, method, headers, body schema and
 * the response field we consume). If the client's request drifts — a field
 * renamed, a header dropped, a segment left unencoded — one of these tests
 * fails before it breaks the integration in production.
 */
@IsTest
private class BillingContractTest {
  private static final Set<String> EXPECTED_BODY_KEYS = new Set<String>{
    'invoice_number',
    'external_id',
    'customer_reference',
    'currency',
    'total_amount',
    'amount_paid',
    'amount_refunded',
    'balance_due',
    'status'
  };

  private static GatewayTestData.BillingMock captureRequest(
    Invoice__c invoice
  ) {
    GatewayTestData.BillingMock mock = new GatewayTestData.BillingMock(
      200,
      '{"id":"bill_contract"}'
    );
    Test.setMock(HttpCalloutMock.class, mock);
    new BillingPlatformClient().pushInvoiceStatus(invoice);
    return mock;
  }

  @IsTest
  static void requestIsPutJsonWithIdempotencyKey() {
    GatewayTestData.configure(true);
    GatewayTestData.invoices(1, 100, 'USD');
    Invoice__c invoice = [
      SELECT
        Id,
        Invoice_Number__c,
        Billing_External_Id__c,
        Customer_Reference__c,
        Currency_Code__c,
        Total_Amount__c,
        Amount_Paid__c,
        Amount_Refunded__c,
        Balance_Due__c,
        Status__c
      FROM Invoice__c
      LIMIT 1
    ];

    HttpRequest request = captureRequest(invoice).requests[0];

    Assert.areEqual('PUT', request.getMethod());
    Assert.areEqual('application/json', request.getHeader('Content-Type'));
    Assert.isNotNull(request.getHeader('Idempotency-Key'));
  }

  @IsTest
  static void bodySchemaMatchesTheContractExactly() {
    GatewayTestData.configure(true);
    GatewayTestData.invoices(1, 100, 'USD');
    Invoice__c invoice = [
      SELECT
        Id,
        Invoice_Number__c,
        Billing_External_Id__c,
        Customer_Reference__c,
        Currency_Code__c,
        Total_Amount__c,
        Amount_Paid__c,
        Amount_Refunded__c,
        Balance_Due__c,
        Status__c
      FROM Invoice__c
      LIMIT 1
    ];

    HttpRequest request = captureRequest(invoice).requests[0];
    Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
      request.getBody()
    );

    Assert.areEqual(
      EXPECTED_BODY_KEYS,
      body.keySet(),
      'body keys drifted from the billing contract'
    );
    Assert.areEqual(invoice.Invoice_Number__c, body.get('invoice_number'));
    Assert.areEqual(
      invoice.Customer_Reference__c,
      body.get('customer_reference')
    );
    Assert.areEqual(invoice.Currency_Code__c, body.get('currency'));
    Assert.areEqual(invoice.Status__c, body.get('status'));
    Assert.areEqual(
      invoice.Total_Amount__c,
      Decimal.valueOf(String.valueOf(body.get('total_amount')))
    );
    Assert.areEqual(
      invoice.Balance_Due__c,
      Decimal.valueOf(String.valueOf(body.get('balance_due')))
    );
  }

  @IsTest
  static void invoiceNumberIsUrlEncodedInTheEndpoint() {
    // An invoice number with '/' '#' and a space must not leak raw into the
    // path segment — it would change the route the platform sees.
    Invoice__c invoice = new Invoice__c(
      Invoice_Number__c = 'INV/2026 #7',
      Currency_Code__c = 'USD',
      Status__c = 'Open'
    );

    HttpRequest request = captureRequest(invoice).requests[0];

    String expected =
      'callout:Billing_Platform/v1/invoices/' +
      EncodingUtil.urlEncode('INV/2026 #7', 'UTF-8') +
      '/payment-status';
    Assert.areEqual(expected, request.getEndpoint());
    Assert.isFalse(
      request.getEndpoint().contains('INV/2026'),
      'invoice number reached the endpoint unencoded'
    );
  }

  @IsTest
  static void idempotencyKeyIsStableAndPaymentSensitive() {
    GatewayTestData.configure(true);
    GatewayTestData.invoices(1, 100, 'USD');
    Invoice__c invoice = [
      SELECT
        Id,
        Invoice_Number__c,
        Billing_External_Id__c,
        Customer_Reference__c,
        Currency_Code__c,
        Total_Amount__c,
        Amount_Paid__c,
        Amount_Refunded__c,
        Balance_Due__c,
        Status__c
      FROM Invoice__c
      LIMIT 1
    ];

    GatewayTestData.BillingMock mock = new GatewayTestData.BillingMock(
      200,
      '{"id":"bill_contract"}'
    );
    Test.setMock(HttpCalloutMock.class, mock);

    BillingPlatformClient client = new BillingPlatformClient();
    client.pushInvoiceStatus(invoice);
    client.pushInvoiceStatus(invoice);
    String stableKey = mock.requests[0].getHeader('Idempotency-Key');
    Assert.areEqual(
      stableKey,
      mock.requests[1].getHeader('Idempotency-Key'),
      'same invoice state must produce the same idempotency key'
    );

    invoice.Amount_Paid__c = 25;
    client.pushInvoiceStatus(invoice);
    Assert.areNotEqual(
      stableKey,
      mock.requests[2].getHeader('Idempotency-Key'),
      'a changed payment position must produce a new idempotency key'
    );
  }

  @IsTest
  static void externalIdIsParsedFromTheIdFieldOnly() {
    Invoice__c result = new Invoice__c();
    // Tolerant parse: blank/invalid/missing "id" leave the field null.
    for (String body : new List<String>{ '', 'not json', '{"other":"x"}' }) {
      Assert.isNull(
        BillingSyncService.parseExternalId(body),
        'body ' + body + ' should not yield an external id'
      );
    }
    Assert.areEqual(
      'bill_9',
      BillingSyncService.parseExternalId('{"id":"bill_9"}')
    );
  }
}
