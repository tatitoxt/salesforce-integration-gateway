/**
 * Minimal trigger handler base class. One trigger per object delegates to a
 * subclass; handlers can be bypassed by name (used by services and tests).
 */
public abstract inherited sharing class TriggerHandler {
  private static Set<String> bypassedHandlers = new Set<String>();

  @TestVisible
  private TriggerOperation operation;
  @TestVisible
  private List<SObject> newRecords;
  @TestVisible
  private Map<Id, SObject> oldRecordsById;

  public TriggerHandler() {
    this(Trigger.operationType, Trigger.new, Trigger.oldMap);
  }

  @TestVisible
  protected TriggerHandler(
    TriggerOperation operation,
    List<SObject> newRecords,
    Map<Id, SObject> oldRecordsById
  ) {
    this.operation = operation;
    this.newRecords = newRecords;
    this.oldRecordsById = oldRecordsById;
  }

  public void run() {
    if (bypassedHandlers.contains(getHandlerName())) {
      return;
    }
    switch on this.operation {
      when BEFORE_INSERT {
        beforeInsert(newRecords);
      }
      when BEFORE_UPDATE {
        beforeUpdate(newRecords, oldRecordsById);
      }
      when AFTER_INSERT {
        afterInsert(newRecords);
      }
      when AFTER_UPDATE {
        afterUpdate(newRecords, oldRecordsById);
      }
      when AFTER_DELETE {
        afterDelete(oldRecordsById);
      }
      when AFTER_UNDELETE {
        afterUndelete(newRecords);
      }
    }
  }

  public static void bypass(String handlerName) {
    bypassedHandlers.add(handlerName);
  }

  public static void clearBypass(String handlerName) {
    bypassedHandlers.remove(handlerName);
  }

  public static Boolean isBypassed(String handlerName) {
    return bypassedHandlers.contains(handlerName);
  }

  /** Name used for bypassing; normally the concrete class name. */
  protected abstract String getHandlerName();

  @SuppressWarnings('PMD.EmptyStatementBlock')
  protected virtual void beforeInsert(List<SObject> records) {
  }

  @SuppressWarnings('PMD.EmptyStatementBlock')
  protected virtual void beforeUpdate(
    List<SObject> records,
    Map<Id, SObject> oldRecords
  ) {
  }

  @SuppressWarnings('PMD.EmptyStatementBlock')
  protected virtual void afterInsert(List<SObject> records) {
  }

  @SuppressWarnings('PMD.EmptyStatementBlock')
  protected virtual void afterUpdate(
    List<SObject> records,
    Map<Id, SObject> oldRecords
  ) {
  }

  @SuppressWarnings('PMD.EmptyStatementBlock')
  protected virtual void afterDelete(Map<Id, SObject> oldRecords) {
  }

  @SuppressWarnings('PMD.EmptyStatementBlock')
  protected virtual void afterUndelete(List<SObject> records) {
  }
}
