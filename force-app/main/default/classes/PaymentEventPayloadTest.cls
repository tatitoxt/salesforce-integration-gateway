@IsTest
private class PaymentEventPayloadTest {
  @IsTest
  static void parsesPaymentEvent() {
    PaymentEventPayload payload = PaymentEventPayload.parse(
      GatewayTestData.paymentEvent('evt_1', 'pi_1', 'INV-1', 12550, 'usd')
    );
    Assert.areEqual('evt_1', payload.eventId);
    Assert.isTrue(payload.isPayment());
    Assert.areEqual('pi_1', payload.objectId);
    Assert.areEqual(125.50, payload.amount);
    Assert.areEqual('USD', payload.currencyCode);
    Assert.areEqual('INV-1', payload.invoiceNumber);
    Assert.areEqual(
      GatewayTestData.NOW_SECONDS * 1000,
      payload.createdAt.getTime()
    );
  }

  @IsTest
  static void parsesRefundEvent() {
    PaymentEventPayload payload = PaymentEventPayload.parse(
      GatewayTestData.refundEvent('evt_2', 're_1', 'pi_1', 500, 'eur')
    );
    Assert.isTrue(payload.isRefund());
    Assert.areEqual('pi_1', payload.paymentIntentId);
    Assert.areEqual(5.00, payload.amount);
  }

  @IsTest
  static void keepsZeroDecimalCurrenciesInMajorUnits() {
    Assert.areEqual(1500, PaymentEventPayload.toMajorUnits(1500, 'JPY'));
    Assert.areEqual(15.00, PaymentEventPayload.toMajorUnits(1500, 'USD'));
  }

  @IsTest
  static void ignoresUnknownTypesWithoutRequiringAmount() {
    PaymentEventPayload payload = PaymentEventPayload.parse(
      GatewayTestData.envelope(
        'evt_3',
        'customer.created',
        new Map<String, Object>{ 'id' => 'cus_1' }
      )
    );
    Assert.isFalse(payload.isPayment());
    Assert.isFalse(payload.isRefund());
  }

  @IsTest
  static void rejectsInvalidPayloads() {
    Map<String, String> cases = new Map<String, String>{
      'not json' => 'invalid_json',
      '[1,2]' => 'invalid_json',
      '{"type":"payment_intent.succeeded"}' => 'missing_event_id',
      '{"id":"evt"}' => 'missing_event_type',
      '{"id":"evt","type":"payment_intent.succeeded","data":{"object":{"id":"pi"}}}' => 'missing_amount',
      '{"id":"evt","type":"payment_intent.succeeded","data":{"object":{"id":"pi","amount":-1}}}' => 'invalid_amount',
      '{"id":"evt","type":"payment_intent.succeeded","data":{"object":{"id":"pi","amount":"10"}}}' => 'invalid_amount',
      '{"id":"evt","type":"refund.created","data":{"object":{"amount":10}}}' => 'missing_object_id'
    };
    for (String body : cases.keySet()) {
      try {
        PaymentEventPayload.parse(body);
        Assert.fail('expected failure for ' + body);
      } catch (PaymentEventPayload.PayloadException e) {
        Assert.areEqual(cases.get(body), e.getMessage(), body);
      }
    }
  }
}
