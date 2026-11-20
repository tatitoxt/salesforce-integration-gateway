trigger InvoiceTrigger on Invoice__c(before update, after update) {
  new InvoiceTriggerHandler().run();
}
