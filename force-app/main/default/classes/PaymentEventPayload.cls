/**
 * Parsed view of a Stripe-style event body. Only the fields the gateway
 * needs are extracted; the raw JSON is stored on Payment_Event__c.
 */
public inherited sharing class PaymentEventPayload {
  public static final String TYPE_PAYMENT_SUCCEEDED = 'payment_intent.succeeded';
  public static final String TYPE_REFUND_CREATED = 'refund.created';
  public static final String TYPE_DISPUTE_CREATED = 'charge.dispute.created';
  public static final String TYPE_INVOICE_PAID = 'invoice.paid';

  private static final Set<String> ZERO_DECIMAL_CURRENCIES = new Set<String>{
    'BIF',
    'CLP',
    'DJF',
    'GNF',
    'JPY',
    'KMF',
    'KRW',
    'MGA',
    'PYG',
    'RWF',
    'UGX',
    'VND',
    'VUV',
    'XAF',
    'XOF',
    'XPF'
  };

  public String eventId;
  public String eventType;
  public Datetime createdAt;
  public String objectId;
  public Decimal amount;
  public String currencyCode;
  public String invoiceNumber;
  public String customerReference;
  public String paymentIntentId;

  public class PayloadException extends Exception {
  }

  public Boolean isPayment() {
    return eventType == TYPE_PAYMENT_SUCCEEDED;
  }

  public Boolean isRefund() {
    return eventType == TYPE_REFUND_CREATED;
  }

  public Boolean isDispute() {
    return eventType == TYPE_DISPUTE_CREATED;
  }

  public Boolean isInvoicePaid() {
    return eventType == TYPE_INVOICE_PAID;
  }

  /** Types the service interprets; anything else parses leniently and is Ignored. */
  public Boolean isActionable() {
    return isPayment() || isRefund() || isDispute() || isInvoicePaid();
  }

  public static PaymentEventPayload parse(String body) {
    Object root;
    try {
      root = JSON.deserializeUntyped(body);
    } catch (JSONException e) {
      throw new PayloadException('invalid_json');
    }
    if (!(root instanceof Map<String, Object>)) {
      throw new PayloadException('invalid_json');
    }
    Map<String, Object> envelope = (Map<String, Object>) root;
    PaymentEventPayload payload = new PaymentEventPayload();
    payload.eventId = asString(envelope.get('id'));
    payload.eventType = asString(envelope.get('type'));
    if (String.isBlank(payload.eventId)) {
      throw new PayloadException('missing_event_id');
    }
    if (String.isBlank(payload.eventType)) {
      throw new PayloadException('missing_event_type');
    }
    if (
      envelope.get('created') instanceof Long ||
      envelope.get('created') instanceof Integer
    ) {
      Long createdSeconds = Long.valueOf(
        String.valueOf(envelope.get('created'))
      );
      payload.createdAt = Datetime.newInstance(createdSeconds * 1000);
    }
    Map<String, Object> dataObject = asMap(
      asMap(envelope.get('data'))?.get('object')
    );
    if (dataObject == null) {
      if (payload.isActionable()) {
        throw new PayloadException('missing_data_object');
      }
      return payload;
    }
    payload.objectId = asString(dataObject.get('id'));
    payload.currencyCode = asString(dataObject.get('currency'))?.toUpperCase();
    payload.amount = toMajorUnits(
      dataObject.get('amount'),
      payload.currencyCode
    );
    payload.paymentIntentId = asString(dataObject.get('payment_intent'));
    payload.customerReference = asString(dataObject.get('customer'));
    Map<String, Object> metadata = asMap(dataObject.get('metadata'));
    if (metadata != null) {
      payload.invoiceNumber = asString(metadata.get('invoice_number'));
    }
    if (payload.isInvoicePaid()) {
      // Invoice objects carry the number on `number` and the total on `amount_paid`.
      payload.invoiceNumber = asString(dataObject.get('number'));
      payload.amount = toMajorUnits(
        dataObject.get('amount_paid'),
        payload.currencyCode
      );
    }
    if (payload.isActionable() && payload.amount == null) {
      throw new PayloadException('missing_amount');
    }
    if (payload.isActionable() && String.isBlank(payload.objectId)) {
      throw new PayloadException('missing_object_id');
    }
    return payload;
  }

  @TestVisible
  private static Decimal toMajorUnits(Object minorUnits, String currencyCode) {
    if (minorUnits == null) {
      return null;
    }
    if (!(minorUnits instanceof Integer || minorUnits instanceof Long)) {
      throw new PayloadException('invalid_amount');
    }
    Decimal value = Decimal.valueOf(String.valueOf(minorUnits));
    if (value < 0) {
      throw new PayloadException('invalid_amount');
    }
    if (
      currencyCode != null && ZERO_DECIMAL_CURRENCIES.contains(currencyCode)
    ) {
      return value.setScale(2);
    }
    return (value / 100).setScale(2);
  }

  private static String asString(Object value) {
    return value == null ? null : String.valueOf(value);
  }

  private static Map<String, Object> asMap(Object value) {
    return value instanceof Map<String, Object>
      ? (Map<String, Object>) value
      : null;
  }
}
