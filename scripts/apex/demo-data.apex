// Synthetic demo invoices used by the simulator scenarios. Safe to re-run.
List<Invoice__c> invoices = new List<Invoice__c>();
Map<String, Decimal> totals = new Map<String, Decimal>{
  'INV-DEMO-0001' => 1200,
  'INV-DEMO-0002' => 500,
  'INV-DEMO-0003' => 450,
  'INV-DEMO-0004' => 80,
  'INV-DEMO-0005' => 75,
  'INV-DEMO-0006' => 640,
  'INV-DEMO-0007' => 320
};
for (String invoiceNumber : totals.keySet()) {
  invoices.add(
    new Invoice__c(
      Name = invoiceNumber,
      Invoice_Number__c = invoiceNumber,
      Customer_Reference__c = 'cus_synthetic_demo',
      Currency_Code__c = 'USD',
      Total_Amount__c = totals.get(invoiceNumber),
      Status__c = 'Open'
    )
  );
}
upsert invoices Invoice_Number__c;
System.debug(invoices.size() + ' demo invoices ready');
