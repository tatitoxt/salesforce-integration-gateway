import { createElement } from "lwc";
import { refreshApex } from "@salesforce/apex";
import ReconciliationConsole, {
  SEARCH_DELAY_MS
} from "c/reconciliationConsole";
import getQueue from "@salesforce/apex/ReconciliationController.getQueue";
import getEventDetail from "@salesforce/apex/ReconciliationController.getEventDetail";
import searchInvoices from "@salesforce/apex/ReconciliationController.searchInvoices";
import retryEvent from "@salesforce/apex/ReconciliationController.retryEvent";
import matchToInvoice from "@salesforce/apex/ReconciliationController.matchToInvoice";
import suggestInvoices from "@salesforce/apex/ReconciliationController.suggestInvoices";

jest.mock(
  "@salesforce/apex/ReconciliationController.getQueue",
  () => {
    const { createApexTestWireAdapter } = require("@salesforce/sfdx-lwc-jest");
    return { default: createApexTestWireAdapter(jest.fn()) };
  },
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/ReconciliationController.getEventDetail",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/ReconciliationController.searchInvoices",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/ReconciliationController.suggestInvoices",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/ReconciliationController.retryEvent",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/ReconciliationController.matchToInvoice",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex",
  () => ({ refreshApex: jest.fn(() => Promise.resolve()) }),
  { virtual: true }
);

const QUEUE = [
  {
    Id: "a01000000000001AAA",
    External_Event_Id__c: "evt_demo_unmatched",
    Event_Type__c: "payment_intent.succeeded",
    Status__c: "Needs_Review",
    Exception_Reason__c: "INVOICE_NOT_FOUND",
    Amount__c: 120,
    Currency_Code__c: "USD",
    Attempts__c: 1
  },
  {
    Id: "a01000000000002AAA",
    External_Event_Id__c: "evt_demo_refund",
    Event_Type__c: "refund.created",
    Status__c: "Dead_Letter",
    Exception_Reason__c: "ORIGINAL_PAYMENT_NOT_FOUND",
    Amount__c: 10,
    Currency_Code__c: "USD",
    Attempts__c: 5
  }
];

const MATCHABLE_DETAIL = {
  event: { ...QUEUE[0], Last_Error__c: null },
  formattedPayload: '{\n  "id" : "evt_demo_unmatched"\n}',
  payments: [
    {
      Id: "a02000000000001AAA",
      Type__c: "Payment",
      Amount__c: 120,
      Currency_Code__c: "USD",
      Status__c: "Unmatched"
    }
  ],
  canRetry: false,
  canMatch: true
};

const RETRYABLE_DETAIL = {
  event: {
    ...QUEUE[1],
    Last_Error__c: "Refund re_1 references unknown payment pi_1"
  },
  formattedPayload: '{\n  "id" : "evt_demo_refund"\n}',
  payments: [],
  canRetry: true,
  canMatch: false
};

const INVOICES = [
  {
    Id: "a00000000000001AAA",
    Invoice_Number__c: "INV-DEMO-0001",
    Currency_Code__c: "USD",
    Balance_Due__c: 120,
    Status__c: "Open"
  }
];

function flushPromises() {
  // eslint-disable-next-line @lwc/lwc/no-async-operation
  return new Promise((resolve) => setTimeout(resolve, 0));
}

function render() {
  const element = createElement("c-reconciliation-console", {
    is: ReconciliationConsole
  });
  document.body.appendChild(element);
  return element;
}

const $ = (element, id) =>
  element.shadowRoot.querySelector(`[data-id="${id}"]`);

async function inspect(element, detail, rowIndex = 0) {
  getEventDetail.mockResolvedValue(detail);
  $(element, "queue").dispatchEvent(
    new CustomEvent("rowaction", {
      detail: { action: { name: "inspect" }, row: QUEUE[rowIndex] }
    })
  );
  await flushPromises();
}

function captureToasts(element) {
  const toasts = [];
  element.addEventListener("lightning__showtoast", (event) =>
    toasts.push(event.detail)
  );
  return toasts;
}

describe("c-reconciliation-console", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
    jest.useRealTimers();
  });

  it("lists events returned by the queue wire", async () => {
    const element = render();
    getQueue.emit(QUEUE);
    await flushPromises();

    expect($(element, "queue").data).toEqual(QUEUE);
    expect($(element, "queue-count").textContent).toContain(
      "2 events need attention"
    );
    expect($(element, "queue-empty")).toBeNull();
  });

  it("shows an empty state and the default status filter", async () => {
    const element = render();
    getQueue.emit([]);
    await flushPromises();

    expect($(element, "queue-empty").textContent).toContain(
      "No events need attention"
    );
    expect(getQueue.getLastConfig()).toEqual({
      statuses: ["Needs_Review", "Retry_Scheduled", "Dead_Letter"]
    });
  });

  it("re-queries when the status filter changes", async () => {
    const element = render();
    getQueue.emit(QUEUE);
    await flushPromises();

    $(element, "status-filter").dispatchEvent(
      new CustomEvent("change", { detail: { value: ["Dead_Letter"] } })
    );
    await flushPromises();

    expect(getQueue.getLastConfig()).toEqual({ statuses: ["Dead_Letter"] });
  });

  it("renders a readable error when the queue cannot be loaded", async () => {
    const element = render();
    getQueue.error({ message: "Insufficient access" });
    await flushPromises();

    expect($(element, "queue-error").textContent).toContain(
      "Insufficient access"
    );
    expect($(element, "queue")).toBeNull();
  });

  it("shows the raw payload, reason and payments when an event is inspected", async () => {
    const element = render();
    getQueue.emit(QUEUE);
    await flushPromises();
    await inspect(element, MATCHABLE_DETAIL);

    expect(getEventDetail).toHaveBeenCalledWith({ eventId: QUEUE[0].Id });
    expect($(element, "detail-title").textContent).toContain(
      "evt_demo_unmatched"
    );
    expect($(element, "payload").textContent).toBe(
      MATCHABLE_DETAIL.formattedPayload
    );
    expect($(element, "detail-reason").textContent).toContain(
      "INVOICE_NOT_FOUND"
    );
    expect($(element, "payments").textContent).toContain("Unmatched");
    expect($(element, "match-panel")).not.toBeNull();
    expect($(element, "retry")).toBeNull();
  });

  it("ignores row actions other than inspect", async () => {
    const element = render();
    getQueue.emit(QUEUE);
    await flushPromises();
    $(element, "queue").dispatchEvent(
      new CustomEvent("rowaction", {
        detail: { action: { name: "other" }, row: QUEUE[0] }
      })
    );
    await flushPromises();
    expect(getEventDetail).not.toHaveBeenCalled();
  });

  it("closes the detail panel", async () => {
    const element = render();
    getQueue.emit(QUEUE);
    await flushPromises();
    await inspect(element, MATCHABLE_DETAIL);

    $(element, "close-detail").click();
    await flushPromises();
    expect($(element, "detail")).toBeNull();
  });

  it("toasts an error when the detail cannot be loaded", async () => {
    const element = render();
    const toasts = captureToasts(element);
    getQueue.emit(QUEUE);
    await flushPromises();

    getEventDetail.mockRejectedValue({
      body: { message: "Event not found or not accessible." }
    });
    $(element, "queue").dispatchEvent(
      new CustomEvent("rowaction", {
        detail: { action: { name: "inspect" }, row: QUEUE[0] }
      })
    );
    await flushPromises();

    expect($(element, "detail")).toBeNull();
    expect(toasts[0]).toMatchObject({
      variant: "error",
      message: "Event not found or not accessible."
    });
  });

  it("retries a dead-lettered event and refreshes the queue", async () => {
    const element = render();
    const toasts = captureToasts(element);
    getQueue.emit(QUEUE);
    await flushPromises();
    await inspect(element, RETRYABLE_DETAIL, 1);
    retryEvent.mockResolvedValue();

    $(element, "retry").click();
    await flushPromises();

    expect(retryEvent).toHaveBeenCalledWith({ eventId: QUEUE[1].Id });
    expect(refreshApex).toHaveBeenCalled();
    expect(toasts[0]).toMatchObject({
      variant: "success",
      title: "Retry queued"
    });
    expect($(element, "detail")).toBeNull();
  });

  it("keeps the detail open and shows the server message when retry fails", async () => {
    const element = render();
    const toasts = captureToasts(element);
    getQueue.emit(QUEUE);
    await flushPromises();
    await inspect(element, RETRYABLE_DETAIL, 1);
    retryEvent.mockRejectedValue({
      body: [
        {
          message:
            "Only events in Retry_Scheduled or Dead_Letter can be retried."
        }
      ]
    });

    $(element, "retry").click();
    await flushPromises();

    expect(toasts[0]).toMatchObject({
      variant: "error",
      message: "Only events in Retry_Scheduled or Dead_Letter can be retried."
    });
    expect($(element, "detail")).not.toBeNull();
    expect(refreshApex).not.toHaveBeenCalled();
  });

  it("searches invoices after a debounce and applies a manual match", async () => {
    jest.useFakeTimers();
    const element = render();
    const toasts = captureToasts(element);
    getQueue.emit(QUEUE);
    await Promise.resolve();
    getEventDetail.mockResolvedValue(MATCHABLE_DETAIL);
    suggestInvoices.mockResolvedValue([]);
    $(element, "queue").dispatchEvent(
      new CustomEvent("rowaction", {
        detail: { action: { name: "inspect" }, row: QUEUE[0] }
      })
    );
    await Promise.resolve();
    await Promise.resolve();
    expect($(element, "match").disabled).toBe(true);

    searchInvoices.mockResolvedValue(INVOICES);
    $(element, "invoice-search").dispatchEvent(
      new CustomEvent("change", { detail: { value: "INV-DEMO" } })
    );
    expect(searchInvoices).not.toHaveBeenCalled();
    jest.advanceTimersByTime(SEARCH_DELAY_MS);
    await Promise.resolve();
    await Promise.resolve();

    expect(searchInvoices).toHaveBeenCalledWith({ term: "INV-DEMO" });
    const results = $(element, "invoice-results");
    expect(results.options).toEqual([
      { value: INVOICES[0].Id, label: "INV-DEMO-0001 · USD 120 due · Open" }
    ]);

    results.dispatchEvent(
      new CustomEvent("change", { detail: { value: INVOICES[0].Id } })
    );
    await Promise.resolve();
    expect($(element, "match").disabled).toBe(false);

    matchToInvoice.mockResolvedValue();
    $(element, "match").click();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    expect(matchToInvoice).toHaveBeenCalledWith({
      eventId: QUEUE[0].Id,
      invoiceId: INVOICES[0].Id
    });
    expect(toasts[0]).toMatchObject({
      variant: "success",
      title: "Payment matched"
    });
    expect(refreshApex).toHaveBeenCalled();
  });

  it("does not search for terms shorter than two characters and reports empty results", async () => {
    jest.useFakeTimers();
    const element = render();
    getQueue.emit(QUEUE);
    await Promise.resolve();
    getEventDetail.mockResolvedValue(MATCHABLE_DETAIL);
    $(element, "queue").dispatchEvent(
      new CustomEvent("rowaction", {
        detail: { action: { name: "inspect" }, row: QUEUE[0] }
      })
    );
    await Promise.resolve();
    await Promise.resolve();

    $(element, "invoice-search").dispatchEvent(
      new CustomEvent("change", { detail: { value: "I" } })
    );
    jest.advanceTimersByTime(SEARCH_DELAY_MS);
    await Promise.resolve();
    expect(searchInvoices).not.toHaveBeenCalled();

    searchInvoices.mockResolvedValue([]);
    $(element, "invoice-search").dispatchEvent(
      new CustomEvent("change", { detail: { value: "ZZ-NOTHING" } })
    );
    jest.advanceTimersByTime(SEARCH_DELAY_MS);
    await Promise.resolve();
    await Promise.resolve();
    expect($(element, "no-invoices").textContent).toContain(
      "No open invoices match"
    );
  });

  it("toasts when invoice search fails", async () => {
    jest.useFakeTimers();
    const element = render();
    const toasts = captureToasts(element);
    getQueue.emit(QUEUE);
    await Promise.resolve();
    getEventDetail.mockResolvedValue(MATCHABLE_DETAIL);
    $(element, "queue").dispatchEvent(
      new CustomEvent("rowaction", {
        detail: { action: { name: "inspect" }, row: QUEUE[0] }
      })
    );
    await Promise.resolve();
    await Promise.resolve();

    searchInvoices.mockRejectedValue(new Error("Search unavailable"));
    $(element, "invoice-search").dispatchEvent(
      new CustomEvent("change", { detail: { value: "INV" } })
    );
    jest.advanceTimersByTime(SEARCH_DELAY_MS);
    await Promise.resolve();
    await Promise.resolve();
    expect(toasts[0]).toMatchObject({
      variant: "error",
      message: "Search unavailable"
    });
  });
});

it("offers amount-based suggestions and matches the picked invoice", async () => {
  const element = render();
  getQueue.emit(QUEUE);
  await Promise.resolve();
  getEventDetail.mockResolvedValue(MATCHABLE_DETAIL);
  suggestInvoices.mockResolvedValue(INVOICES);
  await inspect(element, MATCHABLE_DETAIL);

  expect(suggestInvoices).toHaveBeenCalledWith({ eventId: QUEUE[0].Id });
  const suggestions = $(element, "invoice-suggestions");
  expect(suggestions).not.toBeNull();
  expect(suggestions.options).toEqual([
    { value: INVOICES[0].Id, label: "INV-DEMO-0001 · USD 120 due · Open" }
  ]);

  suggestions.dispatchEvent(
    new CustomEvent("change", { detail: { value: INVOICES[0].Id } })
  );
  await Promise.resolve();
  expect($(element, "match").disabled).toBe(false);

  matchToInvoice.mockResolvedValue();
  $(element, "match").click();
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  expect(matchToInvoice).toHaveBeenCalledWith({
    eventId: QUEUE[0].Id,
    invoiceId: INVOICES[0].Id
  });
});

it("hides the suggestion block when none are offered", async () => {
  const element = render();
  getQueue.emit(QUEUE);
  await Promise.resolve();
  getEventDetail.mockResolvedValue(MATCHABLE_DETAIL);
  suggestInvoices.mockResolvedValue([]);
  await inspect(element, MATCHABLE_DETAIL);
  expect($(element, "invoice-suggestions")).toBeNull();
});
