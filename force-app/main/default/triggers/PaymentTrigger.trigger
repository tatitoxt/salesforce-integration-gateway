trigger PaymentTrigger on Payment__c(
  after insert,
  after update,
  after delete,
  after undelete
) {
  new PaymentTriggerHandler().run();
}
