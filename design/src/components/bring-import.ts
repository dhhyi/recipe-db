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

interface BringWindow extends Window {
  bringwidgets?: { import: BringImport };
  "ga-disable-UA-32355059-8"?: boolean;
}

function loadWidget(document: Document): Promise<BringImport> {
  return new Promise((resolve, reject) => {
    const window = document.defaultView as BringWindow;
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
  });
}

class BringImportComponent extends HTMLElement {
  private frame?: HTMLIFrameElement;

  connectedCallback() {
    // Also runs for HTMX swaps; wait until parsed children are available.
    queueMicrotask(() => void this.initialize());
  }

  disconnectedCallback() {
    // Bring has no documented teardown API; discard its entire runtime.
    this.frame?.remove();
    this.frame = undefined;
  }

  private async initialize() {
    if (this.frame || !this.isConnected) return;
    const widget = this.querySelector<HTMLElement>("[data-bring-language]");
    const fallback = this.querySelector<HTMLAnchorElement>(":scope > a");
    const url = this.dataset.recipeUrl;
    if (!widget || !fallback || !url) return;
    fallback.hidden = false;
    const frame = document.createElement("iframe");
    frame.title = "Bring! – Zur Einkaufsliste";
    frame.style.cssText = "display:block;border:0;width:220px;height:40px";
    this.frame = frame;
    widget.style.cssText = "display:block;position:absolute;visibility:hidden";
    widget.replaceChildren(frame);
    try {
      const document = frame.contentDocument!;
      document.documentElement.lang = "de";
      document.body.style.cssText = "margin:0;display:inline-block";
      const focusStyle = document.createElement("style");
      focusStyle.textContent =
        "a:focus-visible{outline:2px solid currentColor;outline-offset:-2px}";
      document.head.append(focusStyle);
      const mount = document.createElement("div");
      document.body.append(mount);
      const bring = await loadWidget(document);
      if (!this.isConnected || this.frame !== frame) return;
      bring.render(mount, {
        url,
        language: widget.dataset.bringLanguage!,
        baseQuantity: widget.dataset.bringBaseQuantity!,
        requestedQuantity: widget.dataset.bringRequestedQuantity!,
        requiresConsent: true,
      });
      const action = mount.querySelector<HTMLAnchorElement>("a[href]");
      if (!action?.textContent?.trim()) throw new Error("Bring action missing");
      action.setAttribute("aria-label", "Bring! – Zur Einkaufsliste");
      action.target = "_blank";
      action.rel = "noopener noreferrer";
      const bounds = action.getBoundingClientRect();
      frame.style.width = `${Math.ceil(bounds.width)}px`;
      frame.style.height = `${Math.ceil(bounds.height)}px`;
      widget.style.cssText = "";
      if (fallback === window.document.activeElement) action.focus();
      fallback.hidden = true;
    } catch {
      if (this.frame !== frame) return;
      frame.remove();
      widget.style.display = "none";
      fallback.hidden = false;
    }
  }
}

customElements.define("bring-import-component", BringImportComponent);
