/**
 * Recomputes Amount_Paid__c (net of refunds), Amount_Refunded__c and Status__c
 * from applied Payment__c records with one aggregate query per call.
 */
public inherited sharing class InvoiceRollupService {
  private final PaymentSelector paymentSelector = new PaymentSelector();
  private final InvoiceSelector invoiceSelector = new InvoiceSelector();

  public void recalculate(Set<Id> invoiceIds) {
    Set<Id> ids = new Set<Id>(invoiceIds);
    ids.remove(null);
    if (ids.isEmpty()) {
      return;
    }
    Map<Id, Decimal> paidByInvoice = new Map<Id, Decimal>();
    Map<Id, Decimal> refundedByInvoice = new Map<Id, Decimal>();
    for (
      AggregateResult row : paymentSelector.sumAppliedByInvoiceAndType(ids)
    ) {
      Id invoiceId = (Id) row.get('invoiceId');
      Decimal total = (Decimal) row.get('total');
      if ((String) row.get('paymentType') == 'Refund') {
        refundedByInvoice.put(invoiceId, total == null ? 0 : total);
      } else {
        paidByInvoice.put(invoiceId, total == null ? 0 : total);
      }
    }
    List<Invoice__c> changed = new List<Invoice__c>();
    for (Invoice__c invoice : invoiceSelector.selectByIds(ids)) {
      Decimal paid = paidByInvoice.containsKey(invoice.Id)
        ? paidByInvoice.get(invoice.Id)
        : 0;
      Decimal refunded = refundedByInvoice.containsKey(invoice.Id)
        ? refundedByInvoice.get(invoice.Id)
        : 0;
      Decimal net = paid - refunded;
      String status = statusFor(
        invoice.Status__c,
        invoice.Total_Amount__c,
        net
      );
      if (
        invoice.Amount_Paid__c != net ||
        invoice.Amount_Refunded__c != refunded ||
        invoice.Status__c != status
      ) {
        changed.add(
          new Invoice__c(
            Id = invoice.Id,
            Amount_Paid__c = net,
            Amount_Refunded__c = refunded,
            Status__c = status
          )
        );
      }
    }
    update changed;
  }

  @TestVisible
  private static String statusFor(String current, Decimal total, Decimal net) {
    if (current == 'Draft' || current == 'Void') {
      return current;
    }
    Decimal invoiceTotal = total == null ? 0 : total;
    if (net <= 0) {
      return 'Open';
    }
    if (net < invoiceTotal) {
      return 'Partially_Paid';
    }
    if (net == invoiceTotal) {
      return 'Paid';
    }
    return 'Overpaid';
  }
}
