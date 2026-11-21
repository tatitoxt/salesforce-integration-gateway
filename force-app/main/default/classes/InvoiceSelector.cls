/**
 * SOQL for Invoice__c. System-mode methods are used by async integration
 * jobs; USER_MODE methods back the reconciliation console.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public inherited sharing class InvoiceSelector {
  public static final Set<String> PAYABLE_STATUSES = new Set<String>{
    'Open',
    'Partially_Paid',
    'Paid',
    'Overpaid'
  };
  public static final Set<String> OPEN_STATUSES = new Set<String>{
    'Open',
    'Partially_Paid'
  };

  public List<Invoice__c> selectByInvoiceNumbers(Set<String> invoiceNumbers) {
    if (invoiceNumbers == null || invoiceNumbers.isEmpty()) {
      return new List<Invoice__c>();
    }
    return [
      SELECT
        Id,
        Name,
        Invoice_Number__c,
        Customer_Reference__c,
        Currency_Code__c,
        Total_Amount__c,
        Amount_Paid__c,
        Amount_Refunded__c,
        Balance_Due__c,
        Status__c
      FROM Invoice__c
      WHERE Invoice_Number__c IN :invoiceNumbers
    ];
  }

  /**
   * Open invoices grouped by exact Balance_Due__c for amount-based matching:
   * returns every payable invoice whose currency and balance is in the given
   * set, so the caller can keep only currencies/amounts with exactly one row.
   */
  public List<Invoice__c> selectPayableByCurrenciesAndAmounts(
    Set<String> currencies,
    Set<Decimal> amounts
  ) {
    if (
      currencies == null ||
      currencies.isEmpty() ||
      amounts == null ||
      amounts.isEmpty()
    ) {
      return new List<Invoice__c>();
    }
    return [
      SELECT
        Id,
        Name,
        Invoice_Number__c,
        Customer_Reference__c,
        Currency_Code__c,
        Total_Amount__c,
        Amount_Paid__c,
        Amount_Refunded__c,
        Balance_Due__c,
        Status__c
      FROM Invoice__c
      WHERE
        Status__c IN :PAYABLE_STATUSES
        AND Currency_Code__c IN :currencies
        AND Balance_Due__c IN :amounts
    ];
  }

  public List<Invoice__c> selectByIds(Set<Id> invoiceIds) {
    if (invoiceIds == null || invoiceIds.isEmpty()) {
      return new List<Invoice__c>();
    }
    return [
      SELECT
        Id,
        Name,
        Invoice_Number__c,
        Currency_Code__c,
        Total_Amount__c,
        Amount_Paid__c,
        Amount_Refunded__c,
        Balance_Due__c,
        Status__c,
        Billing_Sync_Status__c,
        Billing_Sync_Attempts__c
      FROM Invoice__c
      WHERE Id IN :invoiceIds
    ];
  }

  public List<Invoice__c> selectPaymentPositionForUpdate(Set<Id> invoiceIds) {
    return [
      SELECT Id, Amount_Paid__c, Amount_Refunded__c, Status__c
      FROM Invoice__c
      WHERE Id IN :invoiceIds
      FOR UPDATE
    ];
  }

  public List<Invoice__c> selectDueForBillingSync(Integer limitSize) {
    Datetime now = GatewayClock.now();
    return [
      SELECT
        Id,
        Invoice_Number__c,
        Customer_Reference__c,
        Currency_Code__c,
        Total_Amount__c,
        Amount_Paid__c,
        Amount_Refunded__c,
        Balance_Due__c,
        Status__c,
        Billing_External_Id__c,
        Billing_Sync_Status__c,
        Billing_Sync_Attempts__c,
        Billing_Next_Attempt_At__c
      FROM Invoice__c
      WHERE
        Billing_Sync_Status__c IN ('Pending', 'Retry_Scheduled')
        AND (Billing_Next_Attempt_At__c = NULL
        OR Billing_Next_Attempt_At__c <= :now)
      ORDER BY Billing_Next_Attempt_At__c ASC NULLS FIRST
      LIMIT :limitSize
    ];
  }

  public List<Invoice__c> searchOpenInvoicesAsUser(
    String term,
    Integer limitSize
  ) {
    String likePattern = '%' + (term == null ? '' : term.trim()) + '%';
    return [
      SELECT
        Id,
        Name,
        Invoice_Number__c,
        Customer_Reference__c,
        Currency_Code__c,
        Total_Amount__c,
        Balance_Due__c,
        Status__c
      FROM Invoice__c
      WHERE
        Status__c IN :OPEN_STATUSES
        AND (Invoice_Number__c LIKE :likePattern
        OR Name LIKE :likePattern
        OR Customer_Reference__c LIKE :likePattern)
      WITH USER_MODE
      ORDER BY Invoice_Number__c
      LIMIT :limitSize
    ];
  }

  /**
   * Open invoices in one currency, for amount-based match suggestions. A
   * bounded pool is ranked in Apex by closeness of Balance_Due__c to the
   * payment amount (SOQL cannot order by an expression).
   */
  public List<Invoice__c> selectOpenByCurrencyAsUser(
    String currency,
    Integer limitSize
  ) {
    return [
      SELECT
        Id,
        Name,
        Invoice_Number__c,
        Customer_Reference__c,
        Currency_Code__c,
        Total_Amount__c,
        Balance_Due__c,
        Status__c
      FROM Invoice__c
      WHERE Status__c IN :OPEN_STATUSES AND Currency_Code__c = :currency
      WITH USER_MODE
      ORDER BY Balance_Due__c DESC
      LIMIT :limitSize
    ];
  }

  public List<Invoice__c> selectByIdAsUser(Id invoiceId) {
    return [
      SELECT Id, Invoice_Number__c, Currency_Code__c, Status__c, Balance_Due__c
      FROM Invoice__c
      WHERE Id = :invoiceId
      WITH USER_MODE
      LIMIT 1
    ];
  }
}
