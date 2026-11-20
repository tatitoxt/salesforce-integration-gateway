@IsTest
private class GatewayInfrastructureTest {
  @IsTest
  static void backoffDoublesAndIsCapped() {
    Assert.areEqual(1, RetryPolicy.backoffMinutes(0));
    Assert.areEqual(2, RetryPolicy.backoffMinutes(1));
    Assert.areEqual(8, RetryPolicy.backoffMinutes(3));
    Assert.areEqual(60, RetryPolicy.backoffMinutes(6));
    Assert.areEqual(60, RetryPolicy.backoffMinutes(30));
    Assert.isTrue(RetryPolicy.isExhausted(5, 5));
    Assert.isFalse(RetryPolicy.isExhausted(4, 5));
  }

  @IsTest
  static void retryableStatusCodes() {
    for (Integer code : new List<Integer>{ 408, 429, 500, 502, 503, 504 }) {
      Assert.isTrue(
        RetryPolicy.isRetryableHttpStatus(code),
        String.valueOf(code)
      );
    }
    for (Integer code : new List<Integer>{ 200, 400, 401, 404, 409, 422 }) {
      Assert.isFalse(
        RetryPolicy.isRetryableHttpStatus(code),
        String.valueOf(code)
      );
    }
  }

  @IsTest
  static void settingsFallBackToDefaultsWhenUnset() {
    GatewaySettings.reset();
    Assert.isNull(GatewaySettings.signingSecret());
    Assert.areEqual(
      GatewaySettings.DEFAULT_TOLERANCE_SECONDS,
      GatewaySettings.toleranceSeconds()
    );
    Assert.areEqual(
      GatewaySettings.DEFAULT_MAX_ATTEMPTS,
      GatewaySettings.maxEventAttempts()
    );
    Assert.isFalse(GatewaySettings.billingSyncEnabled());
  }

  @IsTest
  static void invoiceStatusRules() {
    Assert.areEqual('Open', InvoiceRollupService.statusFor('Open', 100, 0));
    Assert.areEqual(
      'Partially_Paid',
      InvoiceRollupService.statusFor('Open', 100, 40)
    );
    Assert.areEqual(
      'Paid',
      InvoiceRollupService.statusFor('Partially_Paid', 100, 100)
    );
    Assert.areEqual(
      'Overpaid',
      InvoiceRollupService.statusFor('Paid', 100, 101)
    );
    Assert.areEqual('Open', InvoiceRollupService.statusFor('Paid', 100, -5));
    Assert.areEqual('Void', InvoiceRollupService.statusFor('Void', 100, 100));
    Assert.areEqual('Draft', InvoiceRollupService.statusFor('Draft', 100, 100));
  }

  @IsTest
  static void bypassedTriggerHandlerDoesNotRun() {
    GatewayTestData.configure(false);
    TriggerHandler.bypass('PaymentEventTriggerHandler');
    Assert.isTrue(TriggerHandler.isBypassed('PaymentEventTriggerHandler'));
    insert new Payment_Event__c(
      External_Event_Id__c = 'evt_bypass',
      Status__c = 'Received',
      Attempts__c = 0
    );
    Assert.isTrue(AsyncJobs.requestedJobs.isEmpty());
    TriggerHandler.clearBypass('PaymentEventTriggerHandler');
    Assert.isFalse(TriggerHandler.isBypassed('PaymentEventTriggerHandler'));
  }

  @IsTest
  static void deletingAndRestoringPaymentRecalculatesInvoice() {
    GatewayTestData.configure(false);
    Invoice__c invoice = GatewayTestData.invoices(1, 100, 'USD')[0];
    Payment__c payment = new Payment__c(
      External_Payment_Id__c = 'pi_manual',
      Invoice__c = invoice.Id,
      Type__c = 'Payment',
      Status__c = 'Applied',
      Amount__c = 100,
      Currency_Code__c = 'USD'
    );
    insert payment;
    Assert.areEqual(
      'Paid',
      GatewayTestData.reloadInvoice(invoice.Id).Status__c
    );
    payment.Amount__c = 30;
    update payment;
    Assert.areEqual(
      'Partially_Paid',
      GatewayTestData.reloadInvoice(invoice.Id).Status__c
    );
    delete payment;
    Assert.areEqual(
      'Open',
      GatewayTestData.reloadInvoice(invoice.Id).Status__c
    );
    undelete payment;
    Assert.areEqual(
      30,
      GatewayTestData.reloadInvoice(invoice.Id).Amount_Paid__c
    );
  }

  @IsTest
  static void sweeperEnqueuesDueWork() {
    GatewayTestData.configure(true);
    GatewayTestData.insertEvents(
      new List<String>{
        GatewayTestData.envelope(
          'evt_sweep',
          'customer.created',
          new Map<String, Object>{ 'id' => 'c' }
        )
      }
    );
    Invoice__c invoice = GatewayTestData.invoices(1, 100, 'USD')[0];
    invoice.Billing_Sync_Status__c = 'Pending';
    TriggerHandler.bypass('InvoiceTriggerHandler');
    update invoice;
    Test.setMock(
      HttpCalloutMock.class,
      new GatewayTestData.BillingMock(200, '{}')
    );
    Test.startTest();
    new GatewaySweeper().execute(null);
    Assert.isTrue(AsyncJobs.enqueuedJobs.contains('PaymentEventProcessor'));
    Assert.isTrue(AsyncJobs.enqueuedJobs.contains('BillingSyncQueueable'));
    Test.stopTest();
  }

  @IsTest
  static void sweeperCanBeScheduled() {
    Test.startTest();
    List<Id> jobIds = GatewaySweeper.scheduleEvery15Minutes();
    Test.stopTest();
    String namePattern = GatewaySweeper.JOB_NAME_PREFIX + '%';
    Assert.areEqual(4, jobIds.size());
    Assert.areEqual(
      4,
      [
        SELECT COUNT()
        FROM CronTrigger
        WHERE CronJobDetail.Name LIKE :namePattern
      ]
    );
  }
}
