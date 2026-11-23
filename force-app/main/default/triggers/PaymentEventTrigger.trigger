trigger PaymentEventTrigger on Payment_Event__c(after insert, after update) {
  new PaymentEventTriggerHandler().run();
}
