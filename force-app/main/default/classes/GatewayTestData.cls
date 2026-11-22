/**
 * Synthetic test data and signed-request helpers shared by Apex tests.
 * The signing secret below is a fixture value, not a real credential.
 */
@IsTest
public class GatewayTestData {
  public static final String SECRET = 'whsec_test_fixture_not_a_real_secret';
  public static final Long NOW_SECONDS = 1767225600L; // 2026-01-01T00:00:00Z

  public static void configure(Boolean billingEnabled) {
    insert new Payment_Gateway_Settings__c(
      SetupOwnerId = UserInfo.getOrganizationId(),
      Webhook_Signing_Secret__c = SECRET,
      Signature_Tolerance_Seconds__c = 300,
      Max_Event_Attempts__c = 3,
      Max_Billing_Attempts__c = 3,
      Billing_Sync_Enabled__c = billingEnabled
    );
    GatewaySettings.reset();
    freezeClock();
  }

  public static void freezeClock() {
    GatewayClock.fixedNow = Datetime.newInstance(NOW_SECONDS * 1000);
  }

  public static List<Invoice__c> invoices(
    Integer count,
    Decimal total,
    String currencyCode
  ) {
    List<Invoice__c> records = new List<Invoice__c>();
    for (Integer i = 0; i < count; i++) {
      String invoiceNumber = invoiceNumber(i);
      records.add(
        new Invoice__c(
          Name = invoiceNumber,
          Invoice_Number__c = invoiceNumber,
          Customer_Reference__c = 'cus_synthetic_' + i,
          Currency_Code__c = currencyCode,
          Total_Amount__c = total,
          Status__c = 'Open',
          Billing_Sync_Status__c = 'Not_Synced'
        )
      );
    }
    insert records;
    return records;
  }

  public static String invoiceNumber(Integer index) {
    return 'INV-TEST-' + String.valueOf(index).leftPad(4, '0');
  }

  public static String paymentEvent(
    String eventId,
    String paymentId,
    String invoiceNumber,
    Long amountMinor,
    String currencyCode
  ) {
    Map<String, Object> metadata = new Map<String, Object>();
    if (invoiceNumber != null) {
      metadata.put('invoice_number', invoiceNumber);
    }
    return envelope(
      eventId,
      PaymentEventPayload.TYPE_PAYMENT_SUCCEEDED,
      new Map<String, Object>{
        'id' => paymentId,
        'object' => 'payment_intent',
        'amount' => amountMinor,
        'currency' => currencyCode,
        'customer' => 'cus_synthetic',
        'metadata' => metadata
      }
    );
  }

  public static String refundEvent(
    String eventId,
    String refundId,
    String paymentId,
    Long amountMinor,
    String currencyCode
  ) {
    return envelope(
      eventId,
      PaymentEventPayload.TYPE_REFUND_CREATED,
      new Map<String, Object>{
        'id' => refundId,
        'object' => 'refund',
        'amount' => amountMinor,
        'currency' => currencyCode,
        'payment_intent' => paymentId
      }
    );
  }

  public static String disputeEvent(
    String eventId,
    String disputeId,
    String paymentId,
    Long amountMinor,
    String currencyCode
  ) {
    return envelope(
      eventId,
      PaymentEventPayload.TYPE_DISPUTE_CREATED,
      new Map<String, Object>{
        'id' => disputeId,
        'object' => 'dispute',
        'amount' => amountMinor,
        'currency' => currencyCode,
        'payment_intent' => paymentId,
        'reason' => 'fraudulent'
      }
    );
  }

  public static String disputeClosedEvent(
    String eventId,
    String disputeId,
    String paymentId,
    String status,
    Long amountMinor,
    String currencyCode
  ) {
    return envelope(
      eventId,
      PaymentEventPayload.TYPE_DISPUTE_CLOSED,
      new Map<String, Object>{
        'id' => disputeId,
        'object' => 'dispute',
        'amount' => amountMinor,
        'currency' => currencyCode,
        'payment_intent' => paymentId,
        'status' => status
      }
    );
  }

  public static String paymentFailedEvent(
    String eventId,
    String paymentIntentId,
    Long amountMinor,
    String currencyCode,
    String invoiceNumber,
    String failureCode,
    String failureMessage
  ) {
    Map<String, Object> metadata = new Map<String, Object>();
    if (String.isNotBlank(invoiceNumber)) {
      metadata.put('invoice_number', invoiceNumber);
    }
    return envelope(
      eventId,
      PaymentEventPayload.TYPE_PAYMENT_FAILED,
      new Map<String, Object>{
        'id' => paymentIntentId,
        'object' => 'payment_intent',
        'amount' => amountMinor,
        'currency' => currencyCode,
        'customer' => 'cus_synthetic',
        'metadata' => metadata,
        'last_payment_error' => new Map<String, Object>{
          'code' => failureCode,
          'message' => failureMessage
        }
      }
    );
  }

  public static String invoicePaidEvent(
    String eventId,
    String invoiceId,
    String invoiceNumber,
    Long amountPaidMinor,
    String currencyCode
  ) {
    return envelope(
      eventId,
      PaymentEventPayload.TYPE_INVOICE_PAID,
      new Map<String, Object>{
        'id' => invoiceId,
        'object' => 'invoice',
        'number' => invoiceNumber,
        'amount_paid' => amountPaidMinor,
        'currency' => currencyCode,
        'customer' => 'cus_synthetic'
      }
    );
  }

  public static String envelope(
    String eventId,
    String type,
    Map<String, Object> dataObject
  ) {
    return JSON.serialize(
      new Map<String, Object>{
        'id' => eventId,
        'object' => 'event',
        'type' => type,
        'created' => NOW_SECONDS,
        'data' => new Map<String, Object>{ 'object' => dataObject }
      }
    );
  }

  public static String signatureHeader(
    String body,
    Long timestampSeconds,
    String secret
  ) {
    String signature = new WebhookSignatureVerifier(secret, 300)
      .computeSignature(timestampSeconds, Blob.valueOf(body));
    return 't=' + timestampSeconds + ',v1=' + signature;
  }

  /** Inserts events without triggering async processing, for direct service tests. */
  public static List<Payment_Event__c> insertEvents(List<String> bodies) {
    List<Payment_Event__c> records = new List<Payment_Event__c>();
    for (String body : bodies) {
      PaymentEventPayload payload = PaymentEventPayload.parse(body);
      records.add(
        new Payment_Event__c(
          External_Event_Id__c = payload.eventId,
          Event_Type__c = payload.eventType,
          Status__c = 'Received',
          Attempts__c = 0,
          Payload__c = body,
          Invoice_Reference__c = payload.invoiceNumber,
          Amount__c = payload.amount,
          Currency_Code__c = payload.currencyCode
        )
      );
    }
    TriggerHandler.bypass('PaymentEventTriggerHandler');
    insert records;
    TriggerHandler.clearBypass('PaymentEventTriggerHandler');
    return records;
  }

  public static Payment_Event__c reload(Id eventId) {
    return [
      SELECT
        Id,
        External_Event_Id__c,
        Payload__c,
        Status__c,
        Attempts__c,
        Next_Attempt_At__c,
        Exception_Reason__c,
        Last_Error__c,
        Processed_At__c
      FROM Payment_Event__c
      WHERE Id = :eventId
    ];
  }

  public static Invoice__c reloadInvoice(Id invoiceId) {
    return [
      SELECT
        Id,
        Status__c,
        Amount_Paid__c,
        Amount_Refunded__c,
        Balance_Due__c,
        Billing_Sync_Status__c,
        Billing_Sync_Attempts__c,
        Billing_Next_Attempt_At__c,
        Billing_Last_Error__c,
        Billing_External_Id__c
      FROM Invoice__c
      WHERE Id = :invoiceId
    ];
  }

  /** Configurable HttpCalloutMock for the billing platform. */
  public class BillingMock implements HttpCalloutMock {
    public Integer statusCode;
    public String body;
    public Boolean throwTimeout = false;
    public List<HttpRequest> requests = new List<HttpRequest>();

    public BillingMock(Integer statusCode, String body) {
      this.statusCode = statusCode;
      this.body = body;
    }

    public HttpResponse respond(HttpRequest request) {
      requests.add(request);
      if (throwTimeout) {
        throw new CalloutException('Read timed out');
      }
      HttpResponse response = new HttpResponse();
      response.setStatusCode(statusCode);
      response.setHeader('Content-Type', 'application/json');
      response.setBody(body);
      return response;
    }
  }
}
