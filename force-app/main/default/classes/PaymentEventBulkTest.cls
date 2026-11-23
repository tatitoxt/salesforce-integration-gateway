@IsTest
private class PaymentEventBulkTest {
  private static final Integer BULK_SIZE = 200;

  @TestSetup
  static void setup() {
    GatewayTestData.configure(false);
    GatewayTestData.invoices(BULK_SIZE, 50, 'USD');
  }

  @IsTest
  static void processes200EventsInOneServiceCall() {
    GatewayTestData.freezeClock();
    List<String> bodies = new List<String>();
    for (Integer i = 0; i < BULK_SIZE; i++) {
      bodies.add(
        GatewayTestData.paymentEvent(
          'evt_bulk_' + i,
          'pi_bulk_' + i,
          GatewayTestData.invoiceNumber(i),
          5000,
          'usd'
        )
      );
    }
    GatewayTestData.insertEvents(bodies);

    Test.startTest();
    new PaymentEventService()
      .process(new PaymentEventSelector().selectDueForProcessing(BULK_SIZE));
    Integer queries = Limits.getQueries();
    Integer dmlStatements = Limits.getDmlStatements();
    Test.stopTest();

    Assert.areEqual(
      BULK_SIZE,
      [SELECT COUNT() FROM Payment_Event__c WHERE Status__c = 'Processed']
    );
    Assert.areEqual(
      BULK_SIZE,
      [SELECT COUNT() FROM Payment__c WHERE Status__c = 'Applied']
    );
    Assert.areEqual(
      BULK_SIZE,
      [SELECT COUNT() FROM Invoice__c WHERE Status__c = 'Paid']
    );
    Assert.isTrue(
      queries < 20,
      'query count must not scale with batch size: ' + queries
    );
    Assert.isTrue(
      dmlStatements < 10,
      'DML count must not scale with batch size: ' + dmlStatements
    );
  }

  @IsTest
  static void bulkWebhookInsertEnqueuesProcessorOnce() {
    GatewayTestData.freezeClock();
    List<Payment_Event__c> records = new List<Payment_Event__c>();
    for (Integer i = 0; i < BULK_SIZE; i++) {
      String body = GatewayTestData.paymentEvent(
        'evt_trg_' + i,
        'pi_trg_' + i,
        GatewayTestData.invoiceNumber(i),
        5000,
        'usd'
      );
      records.add(
        new Payment_Event__c(
          External_Event_Id__c = 'evt_trg_' + i,
          Status__c = 'Received',
          Attempts__c = 0,
          Payload__c = body
        )
      );
    }
    Test.startTest();
    insert records;
    Assert.areEqual(1, AsyncJobs.enqueuedJobs.size());
    Test.stopTest();
    Assert.areEqual(BULK_SIZE, [SELECT COUNT() FROM Payment__c]);
  }
}
