@IsTest
private class PaymentEventProcessorTest {
  @TestSetup
  static void setup() {
    GatewayTestData.configure(false);
    GatewayTestData.invoices(1, 100, 'USD');
  }

  @IsTest
  static void retriesOnlyWhenDue() {
    GatewayTestData.freezeClock();
    List<Payment_Event__c> records = GatewayTestData.insertEvents(
      new List<String>{
        GatewayTestData.refundEvent('evt_r', 're_r', 'pi_missing', 100, 'usd')
      }
    );
    new PaymentEventProcessor().run();
    Assert.areEqual(
      'Retry_Scheduled',
      GatewayTestData.reload(records[0].Id).Status__c
    );
    Assert.isTrue(
      AsyncJobs.wasRequested('PaymentEventProcessor'),
      'follow-up requested for the scheduled retry'
    );

    new PaymentEventProcessor().run();
    Assert.areEqual(
      1,
      GatewayTestData.reload(records[0].Id).Attempts__c,
      'not due yet, untouched'
    );

    GatewayClock.fixedNow = GatewayClock.now().addMinutes(3);
    new PaymentEventProcessor().run();
    Assert.areEqual(2, GatewayTestData.reload(records[0].Id).Attempts__c);
  }

  @IsTest
  static void minutesUntilRoundsUpWithMinimumOfOne() {
    GatewayTestData.freezeClock();
    Datetime now = GatewayClock.now();
    Assert.areEqual(1, PaymentEventProcessor.minutesUntil(now));
    Assert.areEqual(1, PaymentEventProcessor.minutesUntil(now.addSeconds(30)));
    Assert.areEqual(3, PaymentEventProcessor.minutesUntil(now.addSeconds(121)));
  }

  @IsTest
  static void executeRunsAsQueueable() {
    GatewayTestData.freezeClock();
    GatewayTestData.insertEvents(
      new List<String>{
        GatewayTestData.paymentEvent(
          'evt_q',
          'pi_q',
          GatewayTestData.invoiceNumber(0),
          10000,
          'usd'
        )
      }
    );
    Test.startTest();
    System.enqueueJob(new PaymentEventProcessor());
    Test.stopTest();
    Assert.areEqual(
      'Processed',
      [SELECT Status__c FROM Payment_Event__c].Status__c
    );
  }
}
