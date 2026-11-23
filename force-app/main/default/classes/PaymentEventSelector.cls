/**
 * SOQL for Payment_Event__c. selectDueForProcessing locks rows so concurrent
 * processors (trigger-enqueued and sweeper-enqueued) never process the same
 * event twice.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public inherited sharing class PaymentEventSelector {
  public static final Set<String> DUE_STATUSES = new Set<String>{
    'Received',
    'Retry_Scheduled'
  };
  public static final Set<String> EXCEPTION_STATUSES = new Set<String>{
    'Needs_Review',
    'Dead_Letter',
    'Retry_Scheduled'
  };

  public List<Payment_Event__c> selectByExternalIds(Set<String> externalIds) {
    if (externalIds == null || externalIds.isEmpty()) {
      return new List<Payment_Event__c>();
    }
    return [
      SELECT Id, External_Event_Id__c, Status__c
      FROM Payment_Event__c
      WHERE External_Event_Id__c IN :externalIds
    ];
  }

  public List<Payment_Event__c> selectDueForProcessing(Integer limitSize) {
    Datetime now = GatewayClock.now();
    return [
      SELECT
        Id,
        External_Event_Id__c,
        Event_Type__c,
        Status__c,
        Payload__c,
        Attempts__c,
        Next_Attempt_At__c
      FROM Payment_Event__c
      WHERE
        Status__c IN :DUE_STATUSES
        AND (Next_Attempt_At__c = NULL
        OR Next_Attempt_At__c <= :now)
      LIMIT :limitSize
      FOR UPDATE
    ];
  }

  public Integer countDueForProcessing() {
    Datetime now = GatewayClock.now();
    return [
      SELECT COUNT()
      FROM Payment_Event__c
      WHERE
        Status__c IN :DUE_STATUSES
        AND (Next_Attempt_At__c = NULL
        OR Next_Attempt_At__c <= :now)
    ];
  }

  public List<Payment_Event__c> selectNextScheduledRetry() {
    return [
      SELECT Id, Next_Attempt_At__c
      FROM Payment_Event__c
      WHERE Status__c = 'Retry_Scheduled' AND Next_Attempt_At__c != NULL
      ORDER BY Next_Attempt_At__c ASC
      LIMIT 1
    ];
  }

  public List<Payment_Event__c> selectQueueAsUser(
    Set<String> statuses,
    Integer limitSize
  ) {
    return [
      SELECT
        Id,
        Name,
        External_Event_Id__c,
        Event_Type__c,
        Status__c,
        Attempts__c,
        Next_Attempt_At__c,
        Last_Error__c,
        Exception_Reason__c,
        Invoice_Reference__c,
        Amount__c,
        Currency_Code__c,
        CreatedDate
      FROM Payment_Event__c
      WHERE Status__c IN :statuses
      WITH USER_MODE
      ORDER BY CreatedDate DESC
      LIMIT :limitSize
    ];
  }

  public List<Payment_Event__c> selectByIdAsUser(Id eventId) {
    return [
      SELECT
        Id,
        Name,
        External_Event_Id__c,
        Event_Type__c,
        Status__c,
        Attempts__c,
        Next_Attempt_At__c,
        Last_Error__c,
        Exception_Reason__c,
        Invoice_Reference__c,
        Amount__c,
        Currency_Code__c,
        Payload__c,
        Signature_Timestamp__c,
        Event_Created_At__c,
        Processed_At__c,
        CreatedDate
      FROM Payment_Event__c
      WHERE Id = :eventId
      WITH USER_MODE
      LIMIT 1
    ];
  }
}
