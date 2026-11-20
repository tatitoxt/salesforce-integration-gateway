@IsTest
private class WebhookSignatureVerifierTest {
  private static final String SECRET = GatewayTestData.SECRET;
  private static final Long NOW = GatewayTestData.NOW_SECONDS;
  private static final String BODY = '{"id":"evt_sig_1","type":"payment_intent.succeeded"}';

  private static WebhookSignatureVerifier.Result verify(
    String header,
    Long nowSeconds
  ) {
    return new WebhookSignatureVerifier(SECRET, 300)
      .verify(header, Blob.valueOf(BODY), nowSeconds);
  }

  @IsTest
  static void acceptsValidSignature() {
    WebhookSignatureVerifier.Result result = verify(
      GatewayTestData.signatureHeader(BODY, NOW, SECRET),
      NOW
    );
    Assert.isTrue(result.valid, 'valid signature must pass');
    Assert.areEqual(NOW, result.timestampSeconds);
  }

  @IsTest
  static void matchesKnownHmacVector() {
    // Independent vector: HMAC-SHA256(key="key", "1.body"), cross-checked with the Node simulator tests.
    String signature = new WebhookSignatureVerifier('key', 300)
      .computeSignature(1L, Blob.valueOf('body'));
    Assert.areEqual(
      EncodingUtil.convertToHex(
        Crypto.generateMac(
          'hmacSHA256',
          Blob.valueOf('1.body'),
          Blob.valueOf('key')
        )
      ),
      signature
    );
  }

  @IsTest
  static void rejectsWrongSecret() {
    WebhookSignatureVerifier.Result result = verify(
      GatewayTestData.signatureHeader(BODY, NOW, 'another_secret'),
      NOW
    );
    Assert.isFalse(result.valid);
    Assert.areEqual(WebhookSignatureVerifier.REASON_MISMATCH, result.reason);
  }

  @IsTest
  static void rejectsTamperedBody() {
    String header = GatewayTestData.signatureHeader(BODY, NOW, SECRET);
    WebhookSignatureVerifier.Result result = new WebhookSignatureVerifier(
        SECRET,
        300
      )
      .verify(header, Blob.valueOf(BODY + ' '), NOW);
    Assert.areEqual(WebhookSignatureVerifier.REASON_MISMATCH, result.reason);
  }

  @IsTest
  static void rejectsTimestampOutsideTolerance() {
    String header = GatewayTestData.signatureHeader(BODY, NOW - 301, SECRET);
    Assert.areEqual(
      WebhookSignatureVerifier.REASON_STALE,
      verify(header, NOW).reason
    );
    String future = GatewayTestData.signatureHeader(BODY, NOW + 301, SECRET);
    Assert.areEqual(
      WebhookSignatureVerifier.REASON_STALE,
      verify(future, NOW).reason
    );
    String edge = GatewayTestData.signatureHeader(BODY, NOW - 300, SECRET);
    Assert.isTrue(
      verify(edge, NOW).valid,
      'boundary of the window is accepted'
    );
  }

  @IsTest
  static void rejectsMissingAndMalformedHeaders() {
    Assert.areEqual(
      WebhookSignatureVerifier.REASON_MISSING,
      verify(null, NOW).reason
    );
    Assert.areEqual(
      WebhookSignatureVerifier.REASON_MISSING,
      verify('  ', NOW).reason
    );
    Assert.areEqual(
      WebhookSignatureVerifier.REASON_MALFORMED,
      verify('v1=abc', NOW).reason
    );
    Assert.areEqual(
      WebhookSignatureVerifier.REASON_MALFORMED,
      verify('t=abc,v1=abc', NOW).reason
    );
    Assert.areEqual(
      WebhookSignatureVerifier.REASON_MALFORMED,
      verify('t=' + NOW, NOW).reason
    );
  }

  @IsTest
  static void acceptsAnyMatchingV1ForSecretRotation() {
    String valid = GatewayTestData.signatureHeader(BODY, NOW, SECRET)
      .substringAfter('v1=');
    String header =
      't=' +
      NOW +
      ',v1=' +
      '0'.repeat(64) +
      ',v1=' +
      valid.toUpperCase();
    Assert.isTrue(verify(header, NOW).valid);
  }

  @IsTest
  static void constantTimeEqualsHandlesLengthAndNulls() {
    Assert.isTrue(WebhookSignatureVerifier.constantTimeEquals('abc', 'abc'));
    Assert.isFalse(WebhookSignatureVerifier.constantTimeEquals('abc', 'abd'));
    Assert.isFalse(WebhookSignatureVerifier.constantTimeEquals('abc', 'abcd'));
    Assert.isFalse(WebhookSignatureVerifier.constantTimeEquals(null, 'abc'));
  }
}
