@IsTest
private class PaymentEventServiceTest {
  @TestSetup
  static void setup() {
    GatewayTestData.configure(false);
    GatewayTestData.invoices(3, 100, 'USD');
  }

  private static Invoice__c invoice(Integer index) {
    return [
      SELECT Id, Status__c, Amount_Paid__c, Amount_Refunded__c, Balance_Due__c
      FROM Invoice__c
      WHERE Invoice_Number__c = :GatewayTestData.invoiceNumber(index)
    ];
  }

  private static List<Payment_Event__c> process(List<String> bodies) {
    GatewayTestData.freezeClock();
    List<Payment_Event__c> records = GatewayTestData.insertEvents(bodies);
    new PaymentEventService().process(records);
    return records;
  }

  @IsTest
  static void fullPaymentMarksInvoicePaid() {
    List<Payment_Event__c> records = process(
      new List<String>{
        GatewayTestData.paymentEvent(
          'evt_1',
          'pi_1',
          GatewayTestData.invoiceNumber(0),
          10000,
          'usd'
        )
      }
    );
    Assert.areEqual(
      'Processed',
      GatewayTestData.reload(records[0].Id).Status__c
    );
    Payment__c payment = [
      SELECT Status__c, Match_Method__c, Invoice__c, Amount__c
      FROM Payment__c
    ];
    Assert.areEqual('Applied', payment.Status__c);
    Assert.areEqual('Invoice_Number', payment.Match_Method__c);
    Invoice__c updated = invoice(0);
    Assert.areEqual('Paid', updated.Status__c);
    Assert.areEqual(100, updated.Amount_Paid__c);
    Assert.areEqual(0, updated.Balance_Due__c);
  }

  @IsTest
  static void partialPaymentsAccumulate() {
    String invoiceNumber = GatewayTestData.invoiceNumber(0);
    process(
      new List<String>{
        GatewayTestData.paymentEvent(
          'evt_p1',
          'pi_p1',
          invoiceNumber,
          4000,
          'usd'
        )
      }
    );
    Assert.areEqual('Partially_Paid', invoice(0).Status__c);
    Assert.areEqual(60, invoice(0).Balance_Due__c);

    process(
      new List<String>{
        GatewayTestData.paymentEvent(
          'evt_p2',
          'pi_p2',
          invoiceNumber,
          6000,
          'usd'
        )
      }
    );
    Assert.areEqual('Paid', invoice(0).Status__c);
  }

  @IsTest
  static void invoiceNumberMatchIsCaseInsensitive() {
    process(
      new List<String>{
        GatewayTestData.paymentEvent(
          'evt_ci',
          'pi_ci',
          GatewayTestData.invoiceNumber(0).toLowerCase(),
          10000,
          'usd'
        )
      }
    );
    Assert.areEqual('Paid', invoice(0).Status__c);
  }

  @IsTest
  static void overpaymentIsAppliedButFlaggedForReview() {
    List<Payment_Event__c> records = process(
      new List<String>{
        GatewayTestData.paymentEvent(
          'evt_over',
          'pi_over',
          GatewayTestData.invoiceNumber(0),
          12000,
          'usd'
        )
      }
    );
    Payment_Event__c record = GatewayTestData.reload(records[0].Id);
    Assert.areEqual('Needs_Review', record.Status__c);
    Assert.areEqual(
      PaymentEventService.REASON_OVERPAYMENT,
      record.Exception_Reason__c
    );
    Assert.areEqual('Overpaid', invoice(0).Status__c);
  }

  @IsTest
  static void unknownOrMissingInvoiceGoesToExceptionQueue() {
    List<Payment_Event__c> records = process(
      new List<String>{
        GatewayTestData.paymentEvent(
          'evt_unknown',
          'pi_unknown',
          'INV-DOES-NOT-EXIST',
          1000,
          'usd'
        ),
        GatewayTestData.paymentEvent('evt_noref', 'pi_noref', null, 1000, 'usd')
      }
    );
    Payment_Event__c unknown = GatewayTestData.reload(records[0].Id);
    Payment_Event__c noRef = GatewayTestData.reload(records[1].Id);
    Assert.areEqual('Needs_Review', unknown.Status__c);
    Assert.areEqual(
      PaymentEventService.REASON_INVOICE_NOT_FOUND,
      unknown.Exception_Reason__c
    );
    Assert.areEqual(
      PaymentEventService.REASON_MISSING_INVOICE_REFERENCE,
      noRef.Exception_Reason__c
    );
    Assert.areEqual(
      2,
      [
        SELECT COUNT()
        FROM Payment__c
        WHERE Status__c = 'Unmatched' AND Invoice__c = NULL
      ]
    );
  }

  @IsTest
  static void currencyMismatchAndClosedInvoiceAreExceptions() {
    Invoice__c voided = invoice(1);
    voided.Status__c = 'Void';
    update voided;
    List<Payment_Event__c> records = process(
      new List<String>{
        GatewayTestData.paymentEvent(
          'evt_eur',
          'pi_eur',
          GatewayTestData.invoiceNumber(0),
          10000,
          'eur'
        ),
        GatewayTestData.paymentEvent(
          'evt_void',
          'pi_void',
          GatewayTestData.invoiceNumber(1),
          10000,
          'usd'
        )
      }
    );
    Assert.areEqual(
      PaymentEventService.REASON_CURRENCY_MISMATCH,
      GatewayTestData.reload(records[0].Id).Exception_Reason__c
    );
    Assert.areEqual(
      PaymentEventService.REASON_INVOICE_NOT_PAYABLE,
      GatewayTestData.reload(records[1].Id).Exception_Reason__c
    );
    Assert.areEqual(
      2,
      [SELECT COUNT() FROM Payment__c WHERE Status__c = 'Exception']
    );
    Assert.areEqual(
      'Open',
      invoice(0).Status__c,
      'exception payments do not roll up'
    );
  }

  @IsTest
  static void refundReducesAmountPaid() {
    String invoiceNumber = GatewayTestData.invoiceNumber(0);
    process(
      new List<String>{
        GatewayTestData.paymentEvent(
          'evt_pay',
          'pi_r',
          invoiceNumber,
          10000,
          'usd'
        )
      }
    );
    List<Payment_Event__c> records = process(
      new List<String>{
        GatewayTestData.refundEvent('evt_ref', 're_1', 'pi_r', 2500, 'usd')
      }
    );
    Assert.areEqual(
      'Processed',
      GatewayTestData.reload(records[0].Id).Status__c
    );
    Payment__c refund = [
      SELECT Status__c, Match_Method__c, Original_Payment__c, Invoice__c
      FROM Payment__c
      WHERE Type__c = 'Refund'
    ];
    Assert.areEqual('Applied', refund.Status__c);
    Assert.areEqual('Refund_Link', refund.Match_Method__c);
    Invoice__c updated = invoice(0);
    Assert.areEqual(75, updated.Amount_Paid__c);
    Assert.areEqual(25, updated.Amount_Refunded__c);
    Assert.areEqual('Partially_Paid', updated.Status__c);
  }

  @IsTest
  static void paymentAndRefundInSameBatchAreApplied() {
    process(
      new List<String>{
        GatewayTestData.refundEvent('evt_ref_b', 're_b', 'pi_b', 10000, 'usd'),
        GatewayTestData.paymentEvent(
          'evt_pay_b',
          'pi_b',
          GatewayTestData.invoiceNumber(0),
          10000,
          'usd'
        )
      }
    );
    Invoice__c updated = invoice(0);
    Assert.areEqual(0, updated.Amount_Paid__c);
    Assert.areEqual('Open', updated.Status__c);
  }

  @IsTest
  static void refundInDifferentCurrencyIsAnException() {
    process(
      new List<String>{
        GatewayTestData.paymentEvent(
          'evt_pay',
          'pi_cur',
          GatewayTestData.invoiceNumber(0),
          10000,
          'usd'
        )
      }
    );
    List<Payment_Event__c> records = process(
      new List<String>{
        GatewayTestData.refundEvent('evt_ref', 're_cur', 'pi_cur', 2500, 'eur')
      }
    );
    Payment_Event__c event = GatewayTestData.reload(records[0].Id);
    Assert.areEqual('Needs_Review', event.Status__c);
    Assert.areEqual(
      PaymentEventService.REASON_CURRENCY_MISMATCH,
      event.Exception_Reason__c
    );
    Assert.areEqual(
      'Exception',
      [SELECT Status__c FROM Payment__c WHERE Type__c = 'Refund'].Status__c
    );
    Invoice__c updated = invoice(0);
    Assert.areEqual(100, updated.Amount_Paid__c, 'refund not applied');
    Assert.areEqual('Paid', updated.Status__c);
  }

  @IsTest
  static void refundExceedingPaymentIsAnException() {
    process(
      new List<String>{
        GatewayTestData.paymentEvent(
          'evt_pay',
          'pi_x',
          GatewayTestData.invoiceNumber(0),
          5000,
          'usd'
        )
      }
    );
    List<Payment_Event__c> records = process(
      new List<String>{
        GatewayTestData.refundEvent('evt_ref', 're_x', 'pi_x', 6000, 'usd')
      }
    );
    Assert.areEqual(
      PaymentEventService.REASON_REFUND_EXCEEDS_PAYMENT,
      GatewayTestData.reload(records[0].Id).Exception_Reason__c
    );
    Assert.areEqual(50, invoice(0).Amount_Paid__c);
  }

  @IsTest
  static void refundBeforePaymentIsRetriedWithBackoffThenDeadLettered() {
    List<Payment_Event__c> records = process(
      new List<String>{
        GatewayTestData.refundEvent(
          'evt_early',
          're_early',
          'pi_later',
          1000,
          'usd'
        )
      }
    );
    Payment_Event__c record = GatewayTestData.reload(records[0].Id);
    Assert.areEqual('Retry_Scheduled', record.Status__c);
    Assert.areEqual(1, record.Attempts__c);
    Assert.areEqual(
      PaymentEventService.REASON_ORIGINAL_NOT_FOUND,
      record.Exception_Reason__c
    );
    Assert.areEqual(
      GatewayClock.now().addMinutes(2),
      record.Next_Attempt_At__c
    );

    // Max_Event_Attempts__c is 3 in the fixture settings.
    new PaymentEventService().process(new List<Payment_Event__c>{ record });
    Assert.areEqual(
      'Retry_Scheduled',
      GatewayTestData.reload(record.Id).Status__c
    );
    Assert.areEqual(
      GatewayClock.now().addMinutes(4),
      GatewayTestData.reload(record.Id).Next_Attempt_At__c
    );
    new PaymentEventService().process(new List<Payment_Event__c>{ record });
    Payment_Event__c exhausted = GatewayTestData.reload(record.Id);
    Assert.areEqual('Dead_Letter', exhausted.Status__c);
    Assert.areEqual(3, exhausted.Attempts__c);
    Assert.isNull(exhausted.Next_Attempt_At__c);
  }

  @IsTest
  static void invalidStoredPayloadIsDeadLettered() {
    Payment_Event__c record = new Payment_Event__c(
      External_Event_Id__c = 'evt_corrupt',
      Event_Type__c = 'payment_intent.succeeded',
      Status__c = 'Received',
      Attempts__c = 0,
      Payload__c = '{"id":"evt_corrupt","type":"payment_intent.succeeded","data":{"object":{"id":"pi"}}}'
    );
    TriggerHandler.bypass('PaymentEventTriggerHandler');
    insert record;
    new PaymentEventService().process(new List<Payment_Event__c>{ record });
    Payment_Event__c reloaded = GatewayTestData.reload(record.Id);
    Assert.areEqual('Dead_Letter', reloaded.Status__c);
    Assert.areEqual(
      PaymentEventService.REASON_INVALID_PAYLOAD,
      reloaded.Exception_Reason__c
    );
  }

  @IsTest
  static void unsupportedEventTypesAreIgnored() {
    List<Payment_Event__c> records = process(
      new List<String>{
        GatewayTestData.envelope(
          'evt_cust',
          'customer.created',
          new Map<String, Object>{ 'id' => 'cus_1' }
        )
      }
    );
    Assert.areEqual('Ignored', GatewayTestData.reload(records[0].Id).Status__c);
  }

  @IsTest
  static void samePaymentInTwoEventsIsRecordedOnce() {
    String invoiceNumber = GatewayTestData.invoiceNumber(0);
    List<Payment_Event__c> records = process(
      new List<String>{
        GatewayTestData.paymentEvent(
          'evt_a',
          'pi_same',
          invoiceNumber,
          10000,
          'usd'
        ),
        GatewayTestData.paymentEvent(
          'evt_b',
          'pi_same',
          invoiceNumber,
          10000,
          'usd'
        )
      }
    );
    Assert.areEqual(1, [SELECT COUNT() FROM Payment__c]);
    Assert.areEqual(
      'Processed',
      GatewayTestData.reload(records[1].Id).Status__c
    );
    Assert.areEqual('Paid', invoice(0).Status__c);
  }

  @IsTest
  static void disputeOnAppliedPaymentIsRecordedForReview() {
    List<Payment_Event__c> records = process(
      new List<String>{
        GatewayTestData.paymentEvent(
          'evt_p',
          'pi_disp',
          GatewayTestData.invoiceNumber(0),
          10000,
          'usd'
        ),
        GatewayTestData.disputeEvent('evt_d', 'dp_1', 'pi_disp', 10000, 'usd')
      }
    );
    Payment__c dispute = [
      SELECT Status__c, Exception_Reason__c, Original_Payment__c, Invoice__c
      FROM Payment__c
      WHERE Type__c = 'Dispute'
    ];
    Assert.areEqual('Exception', dispute.Status__c);
    Assert.areEqual(
      PaymentEventService.REASON_DISPUTE_OPENED,
      dispute.Exception_Reason__c
    );
    Assert.isNotNull(dispute.Original_Payment__c);
    Assert.isNotNull(dispute.Invoice__c);
    Payment_Event__c record = GatewayTestData.reload(records[1].Id);
    Assert.areEqual('Needs_Review', record.Status__c);
    Assert.areEqual(
      PaymentEventService.REASON_DISPUTE_OPENED,
      record.Exception_Reason__c
    );
  }

  @IsTest
  static void disputeForUnknownPaymentRetries() {
    List<Payment_Event__c> records = process(
      new List<String>{
        GatewayTestData.disputeEvent(
          'evt_d',
          'dp_orphan',
          'pi_missing',
          2500,
          'usd'
        )
      }
    );
    Payment_Event__c record = GatewayTestData.reload(records[0].Id);
    Assert.areEqual('Retry_Scheduled', record.Status__c);
    Assert.areEqual(
      PaymentEventService.REASON_ORIGINAL_NOT_FOUND,
      record.Exception_Reason__c
    );
  }

  @IsTest
  static void duplicateDisputeIsRecordedOnce() {
    List<Payment_Event__c> records = process(
      new List<String>{
        GatewayTestData.paymentEvent(
          'evt_p',
          'pi_dup',
          GatewayTestData.invoiceNumber(0),
          5000,
          'usd'
        ),
        GatewayTestData.disputeEvent('evt_d1', 'dp_dup', 'pi_dup', 5000, 'usd'),
        GatewayTestData.disputeEvent('evt_d2', 'dp_dup', 'pi_dup', 5000, 'usd')
      }
    );
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Payment__c WHERE Type__c = 'Dispute']
    );
    Assert.areEqual(
      'Processed',
      GatewayTestData.reload(records[2].Id).Status__c
    );
  }

  @IsTest
  static void invoicePaidOnOpenInvoiceNeedsReview() {
    List<Payment_Event__c> records = process(
      new List<String>{
        GatewayTestData.invoicePaidEvent(
          'evt_ip',
          'in_1',
          GatewayTestData.invoiceNumber(0),
          10000,
          'usd'
        )
      }
    );
    Payment_Event__c record = GatewayTestData.reload(records[0].Id);
    Assert.areEqual('Needs_Review', record.Status__c);
    Assert.areEqual(
      PaymentEventService.REASON_INVOICE_BALANCE_REMAINING,
      record.Exception_Reason__c
    );
    Assert.areEqual(0, [SELECT COUNT() FROM Payment__c]);
  }

  @IsTest
  static void invoicePaidOnSettledInvoiceIsProcessed() {
    List<Payment_Event__c> records = process(
      new List<String>{
        GatewayTestData.paymentEvent(
          'evt_p',
          'pi_settle',
          GatewayTestData.invoiceNumber(0),
          10000,
          'usd'
        ),
        GatewayTestData.invoicePaidEvent(
          'evt_ip',
          'in_1',
          GatewayTestData.invoiceNumber(0),
          10000,
          'usd'
        )
      }
    );
    Assert.areEqual(
      'Processed',
      GatewayTestData.reload(records[1].Id).Status__c
    );
  }

  @IsTest
  static void invoicePaidForUnknownInvoiceNeedsReview() {
    List<Payment_Event__c> records = process(
      new List<String>{
        GatewayTestData.invoicePaidEvent(
          'evt_ip',
          'in_x',
          'INV-DOES-NOT-EXIST',
          100,
          'usd'
        )
      }
    );
    Payment_Event__c record = GatewayTestData.reload(records[0].Id);
    Assert.areEqual('Needs_Review', record.Status__c);
    Assert.areEqual(
      PaymentEventService.REASON_INVOICE_NOT_FOUND,
      record.Exception_Reason__c
    );
  }
}
