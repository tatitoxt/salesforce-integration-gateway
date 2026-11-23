import { LightningElement, wire } from "lwc";
import { refreshApex } from "@salesforce/apex";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getQueue from "@salesforce/apex/ReconciliationController.getQueue";
import getEventDetail from "@salesforce/apex/ReconciliationController.getEventDetail";
import searchInvoices from "@salesforce/apex/ReconciliationController.searchInvoices";
import retryEvent from "@salesforce/apex/ReconciliationController.retryEvent";
import matchToInvoice from "@salesforce/apex/ReconciliationController.matchToInvoice";
import suggestInvoices from "@salesforce/apex/ReconciliationController.suggestInvoices";

const STATUS_OPTIONS = [
  { label: "Needs review", value: "Needs_Review" },
  { label: "Retry scheduled", value: "Retry_Scheduled" },
  { label: "Dead letter", value: "Dead_Letter" }
];

const COLUMNS = [
  { label: "Event", fieldName: "External_Event_Id__c" },
  { label: "Type", fieldName: "Event_Type__c" },
  { label: "Status", fieldName: "Status__c" },
  { label: "Reason", fieldName: "Exception_Reason__c" },
  { label: "Invoice ref", fieldName: "Invoice_Reference__c" },
  { label: "Amount", fieldName: "Amount__c", type: "number" },
  { label: "Currency", fieldName: "Currency_Code__c" },
  { label: "Attempts", fieldName: "Attempts__c", type: "number" },
  {
    type: "button",
    typeAttributes: { label: "Inspect", name: "inspect", variant: "base" }
  }
];

export const SEARCH_DELAY_MS = 300;
const MIN_SEARCH_LENGTH = 2;

function reduceError(error) {
  if (!error) {
    return "Unknown error";
  }
  if (Array.isArray(error.body)) {
    return error.body.map((item) => item.message).join(", ");
  }
  if (error.body && typeof error.body.message === "string") {
    return error.body.message;
  }
  if (typeof error.message === "string") {
    return error.message;
  }
  return "Unknown error";
}

export default class ReconciliationConsole extends LightningElement {
  columns = COLUMNS;
  statusOptions = STATUS_OPTIONS;
  selectedStatuses = STATUS_OPTIONS.map((option) => option.value);
  events = [];
  error;
  detail;
  searchTerm = "";
  invoiceResults = [];
  suggestions = [];
  hasSearched = false;
  selectedInvoiceId;
  isBusy = false;
  wiredQueue;
  searchTimer;

  @wire(getQueue, { statuses: "$selectedStatuses" })
  wiredEvents(result) {
    this.wiredQueue = result;
    if (result.data) {
      this.events = result.data;
      this.error = undefined;
    } else if (result.error) {
      this.events = [];
      this.error = reduceError(result.error);
    }
  }

  disconnectedCallback() {
    clearTimeout(this.searchTimer);
  }

  get hasEvents() {
    return this.events.length > 0;
  }

  get queueSummary() {
    const count = this.events.length;
    return `${count} event${count === 1 ? "" : "s"} need attention`;
  }

  get detailTitle() {
    const event = this.detail.event;
    return `${event.External_Event_Id__c} (${event.Event_Type__c})`;
  }

  get detailEvent() {
    return this.detail.event;
  }

  get hasPayments() {
    return this.detail.payments && this.detail.payments.length > 0;
  }

  get hasInvoiceResults() {
    return this.invoiceResults.length > 0;
  }

  get searchedWithoutResults() {
    return this.hasSearched && this.invoiceResults.length === 0;
  }

  get suggestionOptions() {
    return this.suggestions.map((invoice) => ({
      value: invoice.Id,
      label: `${invoice.Invoice_Number__c} · ${invoice.Currency_Code__c} ${invoice.Balance_Due__c} due · ${invoice.Status__c}`
    }));
  }

  get hasSuggestions() {
    return this.suggestions.length > 0;
  }

  get invoiceOptions() {
    return this.invoiceResults.map((invoice) => ({
      value: invoice.Id,
      label: `${invoice.Invoice_Number__c} · ${invoice.Currency_Code__c} ${invoice.Balance_Due__c} due · ${invoice.Status__c}`
    }));
  }

  get matchDisabled() {
    return this.isBusy || !this.selectedInvoiceId;
  }

  handleStatusChange(event) {
    this.selectedStatuses = event.detail.value;
  }

  async handleRowAction(event) {
    if (event.detail.action.name === "inspect") {
      await this.loadDetail(event.detail.row.Id);
    }
  }

  handleCloseDetail() {
    this.detail = undefined;
    this.resetMatch();
  }

  handleSearchChange(event) {
    this.searchTerm = event.detail.value || "";
    this.selectedInvoiceId = undefined;
    clearTimeout(this.searchTimer);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.searchTimer = setTimeout(() => this.runSearch(), SEARCH_DELAY_MS);
  }

  handleInvoiceSelect(event) {
    this.selectedInvoiceId = event.detail.value;
  }

  handleRetry() {
    return this.runAction(
      () => retryEvent({ eventId: this.detail.event.Id }),
      "Retry queued",
      "The event was reset and will be reprocessed shortly."
    );
  }

  handleMatch() {
    return this.runAction(
      () =>
        matchToInvoice({
          eventId: this.detail.event.Id,
          invoiceId: this.selectedInvoiceId
        }),
      "Payment matched",
      "The payment was applied to the selected invoice."
    );
  }

  async loadDetail(eventId) {
    this.isBusy = true;
    this.resetMatch();
    try {
      this.detail = await getEventDetail({ eventId });
      if (this.detail?.canMatch) {
        try {
          this.suggestions = (await suggestInvoices({ eventId })) ?? [];
        } catch {
          this.suggestions = []; // suggestions are a convenience, not required
        }
      }
    } catch (error) {
      this.detail = undefined;
      this.toast("error", "Could not load event", reduceError(error));
    } finally {
      this.isBusy = false;
    }
  }

  async runSearch() {
    const term = this.searchTerm.trim();
    if (term.length < MIN_SEARCH_LENGTH) {
      this.invoiceResults = [];
      this.hasSearched = false;
      return;
    }
    try {
      this.invoiceResults = await searchInvoices({ term });
    } catch (error) {
      this.invoiceResults = [];
      this.toast("error", "Invoice search failed", reduceError(error));
    }
    this.hasSearched = true;
  }

  async runAction(action, successTitle, successMessage) {
    this.isBusy = true;
    try {
      await action();
      this.toast("success", successTitle, successMessage);
      this.detail = undefined;
      this.resetMatch();
      await refreshApex(this.wiredQueue);
    } catch (error) {
      this.toast("error", "Action failed", reduceError(error));
    } finally {
      this.isBusy = false;
    }
  }

  resetMatch() {
    clearTimeout(this.searchTimer);
    this.searchTerm = "";
    this.invoiceResults = [];
    this.suggestions = [];
    this.hasSearched = false;
    this.selectedInvoiceId = undefined;
  }

  toast(variant, title, message) {
    this.dispatchEvent(new ShowToastEvent({ variant, title, message }));
  }
}
