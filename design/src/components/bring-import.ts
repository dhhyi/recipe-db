type BringImport = {
  render: (
    element: HTMLElement,
    config: {
      url: string;
      language: string;
      baseQuantity: string;
      requestedQuantity: string;
      requiresConsent: boolean;
    },
  ) => void;
};

declare global {
  interface Window {
    bringwidgets?: { import: BringImport };
    "ga-disable-UA-32355059-8"?: boolean;
  }
}

let widgetScript: Promise<BringImport> | undefined;

function loadWidget(): Promise<BringImport> {
  return (widgetScript ??= new Promise((resolve, reject) => {
    // The widget downloads analytics.js even when consent is required.
    // Disable its tracker before loading; never grant analytics consent.
    window["ga-disable-UA-32355059-8"] = true;
    const script = document.createElement("script");
    script.src = "https://platform.getbring.com/widgets/import.js";
    script.async = true;
    script.dataset.bringRequiresConsent = "true";
    script.onload = () => {
      if (window.bringwidgets?.import?.render) {
        resolve(window.bringwidgets.import);
      } else {
        reject(new Error("Bring widget unavailable"));
      }
    };
    script.onerror = () => reject(new Error("Bring widget failed to load"));
    document.head.append(script);
  }));
}

class BringImportComponent extends HTMLElement {
  private initialized = false;

  connectedCallback() {
    // Also runs for HTMX swaps; wait until parsed children are available.
    queueMicrotask(() => void this.initialize());
  }

  private async initialize() {
    if (this.initialized || !this.isConnected) return;
    const widget = this.querySelector<HTMLElement>("[data-bring-language]");
    const fallback = this.querySelector<HTMLAnchorElement>(":scope > a");
    const url = this.dataset.recipeUrl;
    if (!widget || !fallback || !url) return;
    this.initialized = true;
    try {
      const bring = await loadWidget();
      if (!this.isConnected) {
        this.initialized = false;
        return;
      }
      bring.render(widget, {
        url,
        language: widget.dataset.bringLanguage!,
        baseQuantity: widget.dataset.bringBaseQuantity!,
        requestedQuantity: widget.dataset.bringRequestedQuantity!,
        requiresConsent: true,
      });
      const action = widget.querySelector<HTMLAnchorElement>("a[href]");
      if (!action?.textContent?.trim()) throw new Error("Bring action missing");
      action.setAttribute("aria-label", "Bring! – Zur Einkaufsliste");
      fallback.hidden = true;
    } catch {
      widget.style.display = "none";
      fallback.hidden = false;
    }
  }
}

customElements.define("bring-import-component", BringImportComponent);
