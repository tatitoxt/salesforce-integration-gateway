@IsTest
private class ReconciliationControllerTest {
  @TestSetup
  static void setup() {
    GatewayTestData.configure(false);
    GatewayTestData.invoices(2, 100, 'USD');
    GatewayTestData.freezeClock();
    List<Payment_Event__c> records = GatewayTestData.insertEvents(
      new List<String>{
        GatewayTestData.paymentEvent(
          'evt_unmatched',
          'pi_unmatched',
          'INV-UNKNOWN',
          10000,
          'usd'
        ),
        GatewayTestData.refundEvent(
          'evt_orphan',
          're_orphan',
          'pi_never',
          100,
          'usd'
        )
      }
    );
    new PaymentEventService().process(records);
  }

  private static Payment_Event__c byExternalId(String externalId) {
    return [
      SELECT Id, Status__c, Attempts__c
      FROM Payment_Event__c
      WHERE External_Event_Id__c = :externalId
    ];
  }

  @IsTest
  static void queueListsExceptionStatuses() {
    List<Payment_Event__c> queue = ReconciliationController.getQueue(null);
    Assert.areEqual(2, queue.size());
    List<Payment_Event__c> reviewOnly = ReconciliationController.getQueue(
      new List<String>{ 'Needs_Review', 'Processed' }
    );
    Assert.areEqual(
      1,
      reviewOnly.size(),
      'non-queue statuses are filtered out'
    );
    Assert.areEqual('evt_unmatched', reviewOnly[0].External_Event_Id__c);
  }

  @IsTest
  static void detailIncludesFormattedPayloadAndActions() {
    ReconciliationController.EventDetail detail = ReconciliationController.getEventDetail(
      byExternalId('evt_unmatched').Id
    );
    Assert.isTrue(
      detail.formattedPayload.contains('\n'),
      'payload is pretty-printed'
    );
    Assert.areEqual(1, detail.payments.size());
    Assert.isTrue(detail.canMatch);
    Assert.isFalse(detail.canRetry);

    ReconciliationController.EventDetail orphan = ReconciliationController.getEventDetail(
      byExternalId('evt_orphan').Id
    );
    Assert.isTrue(orphan.canRetry);
    Assert.isFalse(orphan.canMatch);
  }

  @IsTest
  static void manualMatchAppliesPaymentAndResolvesEvent() {
    Payment_Event__c record = byExternalId('evt_unmatched');
    Invoice__c invoice = [
      SELECT Id
      FROM Invoice__c
      WHERE Invoice_Number__c = :GatewayTestData.invoiceNumber(0)
    ];
    ReconciliationController.matchToInvoice(record.Id, invoice.Id);

    Assert.areEqual('Resolved', byExternalId('evt_unmatched').Status__c);
    Payment__c payment = [
      SELECT Status__c, Match_Method__c, Invoice__c
      FROM Payment__c
      WHERE External_Payment_Id__c = 'pi_unmatched'
    ];
    Assert.areEqual('Applied', payment.Status__c);
    Assert.areEqual('Manual', payment.Match_Method__c);
    Assert.areEqual(
      'Paid',
      GatewayTestData.reloadInvoice(invoice.Id).Status__c
    );
  }

  @IsTest
  static void manualMatchRejectsCurrencyMismatchAndClosedInvoices() {
    Payment_Event__c record = byExternalId('evt_unmatched');
    Invoice__c invoice = [
      SELECT Id
      FROM Invoice__c
      WHERE Invoice_Number__c = :GatewayTestData.invoiceNumber(0)
    ];
    invoice.Currency_Code__c = 'EUR';
    update invoice;
    assertThrows(record.Id, invoice.Id, 'Currency mismatch');

    invoice.Currency_Code__c = 'USD';
    invoice.Status__c = 'Void';
    update invoice;
    assertThrows(record.Id, invoice.Id, 'not open for payment');
    assertThrows(
      byExternalId('evt_orphan').Id,
      invoice.Id,
      'Only events in Needs_Review'
    );
    Assert.areEqual(
      'Needs_Review',
      byExternalId('evt_unmatched').Status__c,
      'rejected matches leave the event untouched'
    );
  }

  @IsTest
  static void retryResetsEventAndEnqueuesProcessor() {
    Payment_Event__c record = byExternalId('evt_orphan');
    Test.startTest();
    ReconciliationController.retryEvent(record.Id);
    Payment_Event__c reset = byExternalId('evt_orphan');
    Assert.areEqual('Received', reset.Status__c);
    Assert.areEqual(0, reset.Attempts__c);
    Assert.isTrue(AsyncJobs.enqueuedJobs.contains('PaymentEventProcessor'));
    Test.stopTest();
    Assert.areEqual(
      'Retry_Scheduled',
      byExternalId('evt_orphan').Status__c,
      'payment still missing'
    );
  }

  @IsTest
  static void retryRejectsEventsThatNeedManualReview() {
    try {
      ReconciliationController.retryEvent(byExternalId('evt_unmatched').Id);
      Assert.fail('expected AuraHandledException');
    } catch (AuraHandledException e) {
      Assert.isTrue(
        e.getMessage().contains('Only events in Retry_Scheduled or Dead_Letter')
      );
    }
  }

  @IsTest
  static void invoiceSearchRequiresTwoCharactersAndReturnsOpenInvoices() {
    Assert.isTrue(ReconciliationController.searchInvoices('I').isEmpty());
    Assert.areEqual(
      2,
      ReconciliationController.searchInvoices('INV-TEST').size()
    );
    Assert.areEqual(
      1,
      ReconciliationController.searchInvoices(GatewayTestData.invoiceNumber(1))
        .size()
    );
  }

  @IsTest
  static void prettyPrintFallsBackToRawText() {
    Assert.areEqual(
      'not json',
      ReconciliationController.prettyPrint('not json')
    );
  }

  private static void assertThrows(Id eventId, Id invoiceId, String expected) {
    try {
      ReconciliationController.matchToInvoice(eventId, invoiceId);
      Assert.fail('expected AuraHandledException');
    } catch (AuraHandledException e) {
      Assert.isTrue(e.getMessage().contains(expected), e.getMessage());
    }
  }
}
