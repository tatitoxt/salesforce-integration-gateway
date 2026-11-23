/**
 * POST /services/apexrest/payments/webhook
 * Thin HTTP adapter over WebhookIngestionService.
 */
@RestResource(urlMapping='/payments/webhook')
global with sharing class PaymentWebhookResource {
  public static final String SIGNATURE_HEADER = 'Stripe-Signature';

  @HttpPost
  global static void receive() {
    RestRequest request = RestContext.request;
    RestResponse response = RestContext.response;
    WebhookIngestionService.Outcome outcome = new WebhookIngestionService()
      .ingest(findHeader(request, SIGNATURE_HEADER), request.requestBody);
    response.statusCode = outcome.statusCode;
    response.addHeader('Content-Type', 'application/json');
    response.responseBody = Blob.valueOf(
      JSON.serialize(outcome.toResponseBody())
    );
  }

  @TestVisible
  private static String findHeader(RestRequest request, String name) {
    if (request == null || request.headers == null) {
      return null;
    }
    for (String key : request.headers.keySet()) {
      if (key != null && key.equalsIgnoreCase(name)) {
        return request.headers.get(key);
      }
    }
    return null;
  }
}
