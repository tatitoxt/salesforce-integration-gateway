@IsTest
private class BillingSyncTest {
  @TestSetup
  static void setup() {
    GatewayTestData.configure(true);
    GatewayTestData.invoices(2, 100, 'USD');
  }

  private static Invoice__c markPending(Integer index) {
    Invoice__c invoice = [
      SELECT Id
      FROM Invoice__c
      WHERE Invoice_Number__c = :GatewayTestData.invoiceNumber(index)
    ];
    invoice.Billing_Sync_Status__c = 'Pending';
    TriggerHandler.bypass('InvoiceTriggerHandler');
    update invoice;
    TriggerHandler.clearBypass('InvoiceTriggerHandler');
    return invoice;
  }

  @IsTest
  static void successfulSyncStoresExternalId() {
    GatewayTestData.freezeClock();
    Invoice__c invoice = markPending(0);
    GatewayTestData.BillingMock mock = new GatewayTestData.BillingMock(
      200,
      '{"id":"bill_123"}'
    );
    Test.setMock(HttpCalloutMock.class, mock);

    Test.startTest();
    new BillingSyncQueueable().run();
    Test.stopTest();

    Invoice__c synced = GatewayTestData.reloadInvoice(invoice.Id);
    Assert.areEqual('Synced', synced.Billing_Sync_Status__c);
    Assert.areEqual('bill_123', synced.Billing_External_Id__c);
    Assert.areEqual(1, mock.requests.size());
    HttpRequest request = mock.requests[0];
    Assert.areEqual('PUT', request.getMethod());
    Assert.areEqual(
      'callout:Billing_Platform/v1/invoices/' +
        GatewayTestData.invoiceNumber(0) +
        '/payment-status',
      request.getEndpoint()
    );
    Assert.isNotNull(request.getHeader('Idempotency-Key'));
    Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
      request.getBody()
    );
    Assert.areEqual(
      GatewayTestData.invoiceNumber(0),
      body.get('invoice_number')
    );
    Assert.areEqual('USD', body.get('currency'));
  }

  @IsTest
  static void serverErrorSchedulesRetryWithBackoff() {
    GatewayTestData.freezeClock();
    Invoice__c invoice = markPending(0);
    Test.setMock(
      HttpCalloutMock.class,
      new GatewayTestData.BillingMock(503, '{"error":"unavailable"}')
    );

    Test.startTest();
    new BillingSyncQueueable().run();
    Test.stopTest();

    Invoice__c result = GatewayTestData.reloadInvoice(invoice.Id);
    Assert.areEqual('Retry_Scheduled', result.Billing_Sync_Status__c);
    Assert.areEqual(1, result.Billing_Sync_Attempts__c);
    Assert.areEqual(
      GatewayClock.now().addMinutes(2),
      result.Billing_Next_Attempt_At__c
    );
    Assert.areEqual('HTTP 503', result.Billing_Last_Error__c);
  }

  @IsTest
  static void retriesStopAtMaxAttempts() {
    // No DML in this test: callouts must not follow uncommitted work.
    GatewayTestData.freezeClock();
    Invoice__c invoice = [
      SELECT
        Id,
        Invoice_Number__c,
        Status__c,
        Amount_Paid__c,
        Billing_Sync_Attempts__c
      FROM Invoice__c
      LIMIT 1
    ];
    invoice.Billing_Sync_Attempts__c = 2; // Max_Billing_Attempts__c is 3 in the fixture settings.
    Test.setMock(
      HttpCalloutMock.class,
      new GatewayTestData.BillingMock(500, '')
    );
    Test.startTest();
    List<Invoice__c> updates = new BillingSyncService(
        new BillingPlatformClient()
      )
      .sync(new List<Invoice__c>{ invoice });
    Test.stopTest();
    Assert.areEqual('Failed', updates[0].Billing_Sync_Status__c);
    Assert.areEqual(3, updates[0].Billing_Sync_Attempts__c);
    Assert.isNull(updates[0].Billing_Next_Attempt_At__c);
  }

  @IsTest
  static void rateLimitAndTimeoutAreRetried() {
    GatewayTestData.freezeClock();
    Invoice__c invoice = markPending(0);
    GatewayTestData.BillingMock mock = new GatewayTestData.BillingMock(429, '');
    mock.throwTimeout = true;
    Test.setMock(HttpCalloutMock.class, mock);
    Test.startTest();
    new BillingSyncQueueable().run();
    Test.stopTest();
    Invoice__c result = GatewayTestData.reloadInvoice(invoice.Id);
    Assert.areEqual('Retry_Scheduled', result.Billing_Sync_Status__c);
    Assert.isTrue(result.Billing_Last_Error__c.startsWith('Callout error'));
  }

  @IsTest
  static void clientErrorFailsWithoutRetry() {
    GatewayTestData.freezeClock();
    Invoice__c invoice = markPending(0);
    Test.setMock(
      HttpCalloutMock.class,
      new GatewayTestData.BillingMock(422, '{"error":"invalid invoice"}')
    );
    Test.startTest();
    new BillingSyncQueueable().run();
    Test.stopTest();
    Invoice__c result = GatewayTestData.reloadInvoice(invoice.Id);
    Assert.areEqual('Failed', result.Billing_Sync_Status__c);
    Assert.isNull(result.Billing_Next_Attempt_At__c);
    Assert.isTrue(result.Billing_Last_Error__c.startsWith('HTTP 422'));
  }

  @IsTest
  static void paymentChangeMarksInvoicePendingAndSyncsAfterProcessing() {
    GatewayTestData.freezeClock();
    Test.setMock(
      HttpCalloutMock.class,
      new GatewayTestData.BillingMock(200, '{"id":"bill_9"}')
    );
    GatewayTestData.insertEvents(
      new List<String>{
        GatewayTestData.paymentEvent(
          'evt_b1',
          'pi_b1',
          GatewayTestData.invoiceNumber(1),
          10000,
          'usd'
        )
      }
    );
    Test.startTest();
    new PaymentEventProcessor().run();
    Invoice__c pending = [
      SELECT Billing_Sync_Status__c
      FROM Invoice__c
      WHERE Invoice_Number__c = :GatewayTestData.invoiceNumber(1)
    ];
    Assert.areEqual('Pending', pending.Billing_Sync_Status__c);
    Assert.isTrue(AsyncJobs.wasRequested('BillingSyncQueueable'));
    Test.stopTest();
    Invoice__c synced = [
      SELECT Billing_Sync_Status__c, Status__c
      FROM Invoice__c
      WHERE Invoice_Number__c = :GatewayTestData.invoiceNumber(1)
    ];
    Assert.areEqual('Paid', synced.Status__c);
    Assert.areEqual('Synced', synced.Billing_Sync_Status__c);
  }

  @IsTest
  static void manualInvoiceEditStartsSyncWhenEnabled() {
    GatewayTestData.freezeClock();
    Invoice__c invoice = [
      SELECT Id
      FROM Invoice__c
      WHERE Invoice_Number__c = :GatewayTestData.invoiceNumber(0)
    ];
    invoice.Status__c = 'Void';
    Test.startTest();
    update invoice;
    Assert.isTrue(AsyncJobs.enqueuedJobs.contains('BillingSyncQueueable'));
    Test.setMock(
      HttpCalloutMock.class,
      new GatewayTestData.BillingMock(200, '{}')
    );
    Test.stopTest();
    Assert.areEqual(
      'Synced',
      GatewayTestData.reloadInvoice(invoice.Id).Billing_Sync_Status__c
    );
  }

  @IsTest
  static void parseExternalIdToleratesNonJson() {
    Assert.isNull(BillingSyncService.parseExternalId('not json'));
    Assert.isNull(BillingSyncService.parseExternalId(''));
    Assert.isNull(BillingSyncService.parseExternalId('[1]'));
  }
}
