@IsTest
private class PaymentEventRetryFinalizerTest {
  private class MockFinalizerContext implements System.FinalizerContext {
    private final System.ParentJobResult result;
    private final Exception cause;

    MockFinalizerContext(System.ParentJobResult result, Exception cause) {
      this.result = result;
      this.cause = cause;
    }

    public Id getAsyncApexJobId() {
      return null;
    }

    public String getRequestId() {
      return 'TEST-REQ';
    }

    public System.ParentJobResult getResult() {
      return result;
    }

    public Exception getException() {
      return cause;
    }
  }

  @IsTest
  static void successDoesNotRequeue() {
    new PaymentEventRetryFinalizer(0)
      .execute(new MockFinalizerContext(System.ParentJobResult.SUCCESS, null));
    Assert.isFalse(
      AsyncJobs.wasRequested('PaymentEventProcessor'),
      'a clean run leaves chaining to execute()'
    );
  }

  @IsTest
  static void crashRequeuesImmediatelyWithNextDepth() {
    Boolean enqueued = new PaymentEventRetryFinalizer(0)
      .handleCrash(new NullPointerException());
    Assert.isTrue(enqueued, 'crash depth 0 requeues the processor');
    Assert.isTrue(AsyncJobs.wasRequested('PaymentEventProcessor'));
  }

  @IsTest
  static void crashAtMaxDepthLeavesItToTheSweeper() {
    Boolean enqueued = new PaymentEventRetryFinalizer(
        PaymentEventProcessor.MAX_CRASH_RETRIES
      )
      .handleCrash(new NullPointerException());
    Assert.isFalse(enqueued, 'depth cap reached: sweeper backstop only');
    Assert.isFalse(AsyncJobs.wasRequested('PaymentEventProcessor'));
  }

  @IsTest
  static void executeDispatchesOnlyOnCrash() {
    new PaymentEventRetryFinalizer(0)
      .execute(
        new MockFinalizerContext(
          System.ParentJobResult.UNHANDLED_EXCEPTION,
          new NullPointerException()
        )
      );
    Assert.isTrue(AsyncJobs.wasRequested('PaymentEventProcessor'));
  }
}
