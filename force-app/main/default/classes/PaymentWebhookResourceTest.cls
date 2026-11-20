@IsTest
private class PaymentWebhookResourceTest {
  @TestSetup
  static void setup() {
    GatewayTestData.configure(false);
    GatewayTestData.invoices(1, 100, 'USD');
  }

  private static RestResponse post(
    String body,
    String signatureHeader,
    String headerName
  ) {
    RestRequest request = new RestRequest();
    request.requestURI = '/services/apexrest/payments/webhook';
    request.httpMethod = 'POST';
    request.requestBody = body == null ? null : Blob.valueOf(body);
    if (signatureHeader != null) {
      request.addHeader(headerName, signatureHeader);
    }
    RestContext.request = request;
    RestContext.response = new RestResponse();
    PaymentWebhookResource.receive();
    return RestContext.response;
  }

  private static RestResponse postSigned(String body) {
    return post(
      body,
      GatewayTestData.signatureHeader(
        body,
        GatewayTestData.NOW_SECONDS,
        GatewayTestData.SECRET
      ),
      PaymentWebhookResource.SIGNATURE_HEADER
    );
  }

  private static Map<String, Object> json(RestResponse response) {
    return (Map<String, Object>) JSON.deserializeUntyped(
      response.responseBody.toString()
    );
  }

  @IsTest
  static void validEventIsStoredAndProcessedAsynchronously() {
    GatewayTestData.freezeClock();
    String body = GatewayTestData.paymentEvent(
      'evt_ok',
      'pi_ok',
      GatewayTestData.invoiceNumber(0),
      10000,
      'usd'
    );

    Test.startTest();
    RestResponse response = postSigned(body);
    Assert.areEqual(202, response.statusCode);
    Assert.areEqual('accepted', json(response).get('status'));
    Assert.areEqual(
      1,
      AsyncJobs.enqueuedJobs.size(),
      'processor enqueued once'
    );
    Test.stopTest();

    Payment_Event__c record = [
      SELECT Status__c, Amount__c, Currency_Code__c, Invoice_Reference__c
      FROM Payment_Event__c
    ];
    Assert.areEqual('Processed', record.Status__c);
    Assert.areEqual(100.00, record.Amount__c);
    Assert.areEqual(
      GatewayTestData.invoiceNumber(0),
      record.Invoice_Reference__c
    );
    Assert.areEqual('Paid', [SELECT Status__c FROM Invoice__c].Status__c);
  }

  @IsTest
  static void invalidSignatureIsRejectedAndNothingIsStored() {
    GatewayTestData.freezeClock();
    String body = GatewayTestData.paymentEvent(
      'evt_bad',
      'pi_bad',
      'INV-X',
      100,
      'usd'
    );
    RestResponse response = post(
      body,
      GatewayTestData.signatureHeader(
        body,
        GatewayTestData.NOW_SECONDS,
        'wrong_secret'
      ),
      PaymentWebhookResource.SIGNATURE_HEADER
    );
    Assert.areEqual(401, response.statusCode);
    Assert.areEqual(
      WebhookSignatureVerifier.REASON_MISMATCH,
      json(response).get('error')
    );
    Assert.areEqual(0, [SELECT COUNT() FROM Payment_Event__c]);
  }

  @IsTest
  static void staleTimestampIsRejected() {
    GatewayTestData.freezeClock();
    String body = GatewayTestData.paymentEvent(
      'evt_old',
      'pi_old',
      'INV-X',
      100,
      'usd'
    );
    RestResponse response = post(
      body,
      GatewayTestData.signatureHeader(
        body,
        GatewayTestData.NOW_SECONDS - 600,
        GatewayTestData.SECRET
      ),
      PaymentWebhookResource.SIGNATURE_HEADER
    );
    Assert.areEqual(401, response.statusCode);
    Assert.areEqual(
      WebhookSignatureVerifier.REASON_STALE,
      json(response).get('error')
    );
  }

  @IsTest
  static void missingSignatureHeaderIsRejected() {
    GatewayTestData.freezeClock();
    RestResponse response = post('{"id":"evt"}', null, null);
    Assert.areEqual(401, response.statusCode);
    Assert.areEqual(
      WebhookSignatureVerifier.REASON_MISSING,
      json(response).get('error')
    );
  }

  @IsTest
  static void headerLookupIsCaseInsensitive() {
    GatewayTestData.freezeClock();
    String body = GatewayTestData.paymentEvent(
      'evt_case',
      'pi_case',
      'INV-X',
      100,
      'usd'
    );
    RestResponse response = post(
      body,
      GatewayTestData.signatureHeader(
        body,
        GatewayTestData.NOW_SECONDS,
        GatewayTestData.SECRET
      ),
      'stripe-signature'
    );
    Assert.areEqual(202, response.statusCode);
  }

  @IsTest
  static void duplicateEventReturns200WithoutSecondRecord() {
    GatewayTestData.freezeClock();
    String body = GatewayTestData.paymentEvent(
      'evt_dup',
      'pi_dup',
      GatewayTestData.invoiceNumber(0),
      100,
      'usd'
    );
    RestResponse first = postSigned(body);
    RestResponse second = postSigned(body);
    Assert.areEqual(202, first.statusCode);
    Assert.areEqual(200, second.statusCode);
    Assert.areEqual('duplicate', json(second).get('status'));
    Assert.areEqual(json(first).get('recordId'), json(second).get('recordId'));
    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM Payment_Event__c
        WHERE External_Event_Id__c = 'evt_dup'
      ]
    );
  }

  @IsTest
  static void missingSecretFailsClosed() {
    delete [SELECT Id FROM Payment_Gateway_Settings__c];
    GatewaySettings.reset();
    GatewayTestData.freezeClock();
    String body = GatewayTestData.paymentEvent(
      'evt_cfg',
      'pi_cfg',
      'INV-X',
      100,
      'usd'
    );
    RestResponse response = postSigned(body);
    Assert.areEqual(503, response.statusCode);
    Assert.areEqual('gateway_not_configured', json(response).get('error'));
    Assert.areEqual(0, [SELECT COUNT() FROM Payment_Event__c]);
  }

  @IsTest
  static void malformedJsonAndEmptyBodyAreRejected() {
    GatewayTestData.freezeClock();
    Assert.areEqual(400, postSigned('{not json').statusCode);
    Assert.areEqual('invalid_json', json(RestContext.response).get('error'));
    Assert.areEqual(
      400,
      post(null, 't=1,v1=00', PaymentWebhookResource.SIGNATURE_HEADER)
        .statusCode
    );
    Assert.areEqual(0, [SELECT COUNT() FROM Payment_Event__c]);
  }

  @IsTest
  static void oversizedPayloadIsRejected() {
    GatewayTestData.freezeClock();
    String body = GatewayTestData.envelope(
      'evt_big',
      'customer.updated',
      new Map<String, Object>{
        'id' => 'cus_1',
        'note' => 'x'.repeat(WebhookIngestionService.MAX_PAYLOAD_LENGTH)
      }
    );
    Assert.areEqual(413, postSigned(body).statusCode);
  }
}
