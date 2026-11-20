// Usage: replace REPLACE_WITH_SECRET locally before running; never commit the real value.
Payment_Gateway_Settings__c settings = Payment_Gateway_Settings__c.getOrgDefaults();
settings.Webhook_Signing_Secret__c = 'REPLACE_WITH_SECRET';
settings.Signature_Tolerance_Seconds__c = 300;
settings.Max_Event_Attempts__c = 5;
settings.Max_Billing_Attempts__c = 5;
upsert settings;
GatewaySweeper.scheduleEvery15Minutes();
