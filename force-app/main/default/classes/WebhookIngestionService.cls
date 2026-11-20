/**
 * Synchronous part of the webhook: authenticate, validate, de-duplicate and
 * persist. Business processing happens later in PaymentEventProcessor.
 */
public inherited sharing class WebhookIngestionService {
  public static final Integer MAX_PAYLOAD_LENGTH = 131072;

  public class Outcome {
    public Integer statusCode;
    public String status;
    public String eventId;
    public Id recordId;
    public String error;

    public Map<String, Object> toResponseBody() {
      Map<String, Object> body = new Map<String, Object>{ 'status' => status };
      if (eventId != null) {
        body.put('eventId', eventId);
      }
      if (recordId != null) {
        body.put('recordId', recordId);
      }
      if (error != null) {
        body.put('error', error);
      }
      return body;
    }
  }

  private final PaymentEventSelector eventSelector;

  public WebhookIngestionService() {
    this(new PaymentEventSelector());
  }

  @TestVisible
  private WebhookIngestionService(PaymentEventSelector eventSelector) {
    this.eventSelector = eventSelector;
  }

  public Outcome ingest(String signatureHeader, Blob rawBody) {
    String secret = GatewaySettings.signingSecret();
    if (String.isBlank(secret)) {
      return rejected(503, 'gateway_not_configured');
    }
    if (rawBody == null || rawBody.size() == 0) {
      return rejected(400, 'empty_body');
    }
    WebhookSignatureVerifier.Result signature = new WebhookSignatureVerifier(
        secret,
        GatewaySettings.toleranceSeconds()
      )
      .verify(signatureHeader, rawBody, GatewayClock.nowUnixSeconds());
    if (!signature.valid) {
      return rejected(401, signature.reason);
    }
    String body = rawBody.toString();
    if (body.length() > MAX_PAYLOAD_LENGTH) {
      return rejected(413, 'payload_too_large');
    }
    PaymentEventPayload payload;
    try {
      payload = PaymentEventPayload.parse(body);
    } catch (PaymentEventPayload.PayloadException e) {
      return rejected(400, e.getMessage());
    }

    List<Payment_Event__c> existing = eventSelector.selectByExternalIds(
      new Set<String>{ payload.eventId }
    );
    if (!existing.isEmpty()) {
      return duplicate(payload.eventId, existing[0].Id);
    }

    Payment_Event__c record = new Payment_Event__c(
      External_Event_Id__c = payload.eventId,
      Event_Type__c = payload.eventType,
      Status__c = 'Received',
      Attempts__c = 0,
      Payload__c = body,
      Signature_Timestamp__c = Datetime.newInstance(
        signature.timestampSeconds * 1000
      ),
      Event_Created_At__c = payload.createdAt,
      Invoice_Reference__c = payload.invoiceNumber?.left(40),
      Amount__c = payload.amount,
      Currency_Code__c = payload.currencyCode
    );
    Database.SaveResult saveResult = Database.insert(record, false);
    if (!saveResult.isSuccess()) {
      if (isDuplicateValue(saveResult.getErrors())) {
        // Lost a race with a concurrent delivery of the same event.
        List<Payment_Event__c> winner = eventSelector.selectByExternalIds(
          new Set<String>{ payload.eventId }
        );
        return duplicate(
          payload.eventId,
          winner.isEmpty() ? null : winner[0].Id
        );
      }
      return rejected(500, 'storage_error');
    }
    Outcome outcome = new Outcome();
    outcome.statusCode = 202;
    outcome.status = 'accepted';
    outcome.eventId = payload.eventId;
    outcome.recordId = saveResult.getId();
    return outcome;
  }

  private static Boolean isDuplicateValue(List<Database.Error> errors) {
    for (Database.Error error : errors) {
      if (error.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
        return true;
      }
    }
    return false;
  }

  private static Outcome duplicate(String eventId, Id recordId) {
    Outcome outcome = new Outcome();
    outcome.statusCode = 200;
    outcome.status = 'duplicate';
    outcome.eventId = eventId;
    outcome.recordId = recordId;
    return outcome;
  }

  private static Outcome rejected(Integer statusCode, String error) {
    Outcome outcome = new Outcome();
    outcome.statusCode = statusCode;
    outcome.status = 'rejected';
    outcome.error = error;
    return outcome;
  }
}
