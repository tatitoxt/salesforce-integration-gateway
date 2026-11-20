/**
 * Verifies Stripe-style signature headers:
 *   Stripe-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<raw body>")>
 * Multiple v1 entries are accepted (secret rotation). Comparison is
 * constant-time and the timestamp must be within the tolerance window.
 */
public inherited sharing class WebhookSignatureVerifier {
  public static final String REASON_MISSING = 'missing_signature';
  public static final String REASON_MALFORMED = 'malformed_signature';
  public static final String REASON_STALE = 'stale_timestamp';
  public static final String REASON_MISMATCH = 'signature_mismatch';

  public class Result {
    public Boolean valid = false;
    public String reason;
    public Long timestampSeconds;
  }

  private final String secret;
  private final Integer toleranceSeconds;

  public WebhookSignatureVerifier(String secret, Integer toleranceSeconds) {
    this.secret = secret;
    this.toleranceSeconds = toleranceSeconds;
  }

  public Result verify(String header, Blob rawBody, Long nowSeconds) {
    Result result = new Result();
    if (String.isBlank(header)) {
      result.reason = REASON_MISSING;
      return result;
    }
    Long timestamp;
    List<String> candidates = new List<String>();
    for (String part : header.split(',')) {
      String item = part.trim();
      Integer separator = item.indexOf('=');
      if (separator <= 0) {
        continue;
      }
      String key = item.substring(0, separator);
      String value = item.substring(separator + 1);
      if (key == 't') {
        timestamp = parseSeconds(value);
      } else if (key == 'v1') {
        candidates.add(value.toLowerCase());
      }
    }
    if (timestamp == null || candidates.isEmpty()) {
      result.reason = REASON_MALFORMED;
      return result;
    }
    result.timestampSeconds = timestamp;
    if (Math.abs(nowSeconds - timestamp) > toleranceSeconds) {
      result.reason = REASON_STALE;
      return result;
    }
    String expected = computeSignature(timestamp, rawBody);
    for (String candidate : candidates) {
      if (constantTimeEquals(expected, candidate)) {
        result.valid = true;
        result.reason = null;
        return result;
      }
    }
    result.reason = REASON_MISMATCH;
    return result;
  }

  public String computeSignature(Long timestamp, Blob rawBody) {
    // Concatenate at the byte level so non-ASCII bodies are signed exactly as sent.
    Blob signedPayload = EncodingUtil.convertFromHex(
      EncodingUtil.convertToHex(Blob.valueOf(String.valueOf(timestamp) + '.')) +
      EncodingUtil.convertToHex(rawBody == null ? Blob.valueOf('') : rawBody)
    );
    Blob mac = Crypto.generateMac(
      'hmacSHA256',
      signedPayload,
      Blob.valueOf(secret)
    );
    return EncodingUtil.convertToHex(mac);
  }

  @TestVisible
  private static Boolean constantTimeEquals(String left, String right) {
    if (left == null || right == null || left.length() != right.length()) {
      return false;
    }
    Integer difference = 0;
    for (Integer i = 0; i < left.length(); i++) {
      difference = difference | (left.charAt(i) ^ right.charAt(i));
    }
    return difference == 0;
  }

  private static Long parseSeconds(String value) {
    if (String.isBlank(value) || !value.isNumeric()) {
      return null;
    }
    return Long.valueOf(value);
  }
}
