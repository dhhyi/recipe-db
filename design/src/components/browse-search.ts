type BrowseEntry = {
  id: string;
  q: string;
  sort: string;
  explicit: boolean;
  page: number;
  scroll: number;
  stopped: boolean;
};

const historyKey = "__browseSearch";
const storageKey = "recipe-db:browse-history";
const rootSelector = "[data-browse-search], browse-search";
const regionSelector = "[data-browse-results], #browse-results";
const itemsSelector = "[data-browse-items], [data-recipe-list]";
const moreSelector = "[data-browse-more], [data-load-more]";
const errorMessage = "Rezepte konnten nicht geladen werden.";
const fallbackMessage = "Suche nicht verfügbar. Alle Rezepte werden angezeigt.";
const controllers = new WeakMap<HTMLElement, BrowseSearch>();
let active: BrowseSearch | undefined;
let documentInitialized = false;

function readEntries(): BrowseEntry[] {
  try {
    const entries: unknown = JSON.parse(
      sessionStorage.getItem(storageKey) || "[]",
    );
    return Array.isArray(entries)
      ? entries
          .filter(
            (entry): entry is BrowseEntry =>
              typeof entry?.id === "string" &&
              typeof entry.q === "string" &&
              typeof entry.sort === "string" &&
              typeof entry.explicit === "boolean" &&
              typeof entry.stopped === "boolean" &&
              Number.isInteger(entry.page) &&
              entry.page > 0 &&
              Number.isFinite(entry.scroll),
          )
          .slice(-30)
      : [];
  } catch {
    return [];
  }
}

let entries = readEntries();

// HTMX 2 replaces the current state with {htmx:true} when taking a snapshot.
// Keep our entry identity, without carrying it into newly pushed entries.
const replaceState = history.replaceState.bind(history);
history.replaceState = (state, unused, url) => {
  if (
    state?.htmx &&
    !state[historyKey] &&
    history.state?.[historyKey] &&
    (!url || new URL(url, location.href).href === location.href)
  ) {
    state = { ...state, [historyKey]: history.state[historyKey] };
  }
  replaceState(state, unused, url);
};

/** Enhances server HTML without replacing the live form or taking input focus. */
class BrowseSearch {
  readonly root: HTMLElement;
  private form: HTMLFormElement;
  private input: HTMLInputElement;
  private sort: HTMLSelectElement;
  private timer?: ReturnType<typeof setTimeout>;
  private request?: AbortController;
  private observer?: IntersectionObserver;
  private generation = 0;
  private composing = false;
  private appending = false;
  private stopped = false;
  private restoring = false;
  private pending = false;
  private explicit = false;
  private entry: BrowseEntry;

  constructor(root: HTMLElement, freshDocument: boolean) {
    this.root = root;
    this.form = root.querySelector<HTMLFormElement>("form")!;
    this.input = this.form.querySelector<HTMLInputElement>('[name="q"]')!;
    this.sort = this.form.querySelector<HTMLSelectElement>('[name="sort"]')!;
    this.sort.setAttribute("aria-label", "Sortieren nach");
    this.form.setAttribute("hx-boost", "false");
    const status = this.region.querySelector("[data-browse-status]");
    if (status) this.form.after(status);
    let saved = entries.find(
      (entry) => entry.id === history.state?.[historyKey],
    );
    const navigation = performance.getEntriesByType("navigation")[0] as
      PerformanceNavigationTiming | undefined;
    if (freshDocument && saved && navigation?.type !== "back_forward") {
      saved = {
        ...saved, q: this.input.value, sort: this.sort.value,
        explicit: Boolean(new URL(location.href).searchParams.get("sort")),
        page: 1, scroll: 0, stopped: false,
      };
    }
    this.entry = saved || {
      id: Array.from(crypto.getRandomValues(new Uint32Array(4)), (value) => value.toString(16)).join("-"),
      q: this.input.value,
      sort: this.sort.value,
      explicit: Boolean(new URL(location.href).searchParams.get("sort")),
      page: this.page,
      scroll: scrollY,
      stopped: false,
    };
    this.explicit = this.entry.explicit;
    history.replaceState({ ...history.state, [historyKey]: this.entry.id }, "");
    this.input.addEventListener("compositionstart", () => {
      this.composing = true;
      this.cancel();
    });
    this.input.addEventListener("compositionend", () => {
      this.composing = false;
      this.edit(false);
    });
    this.input.addEventListener("input", (event) => {
      if (!this.composing && !(event as InputEvent).isComposing)
        this.edit(false);
    });
    this.form.addEventListener("submit", (event) => {
      event.preventDefault();
      if (!this.composing) this.edit(true);
    });
    this.input.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && (this.composing || event.isComposing)) {
        event.preventDefault();
      }
    });
    this.sort.addEventListener("change", () => {
      this.explicit = Boolean(this.sort.value);
      if (!this.composing) this.edit(true);
    });
    this.root.addEventListener("click", (event) => {
      if ((event.target as Element).closest(moreSelector)) {
        event.preventDefault();
        void this.append();
      }
    });
    this.root.addEventListener("htmx:beforeRequest", (event) => {
      if (this.form.contains(event.target as Node)) event.preventDefault();
    });
    this.activate(saved);
  }

  private get region() {
    return this.root.querySelector<HTMLElement>(regionSelector)!;
  }

  private get page() {
    return Number(this.region.dataset.page) || 1;
  }

  private get fallback() {
    return (
      this.region.dataset.fallback === "true" ||
      this.region.dataset.kind === "fallback"
    );
  }

  private get signature() {
    return JSON.stringify([
      this.input.value.trim(),
      this.sort.value,
      this.explicit,
    ]);
  }

  private status(message: string) {
    const status = this.root.querySelector<HTMLElement>("[data-browse-status]");
    if (status) status.textContent = message;
  }

  save() {
    if (this.restoring || this.composing || !this.root.isConnected) return;
    this.entry = {
      ...this.entry,
      q: this.input.value,
      sort: this.sort.value,
      explicit: this.explicit,
      page: this.pending ? 1 : this.page,
      scroll: scrollY,
      stopped: this.stopped,
    };
    entries = [
      ...entries.filter((entry) => entry.id !== this.entry.id),
      this.entry,
    ].slice(-30);
    try {
      sessionStorage.setItem(storageKey, JSON.stringify(entries));
    } catch {
      // History restoration still works in memory when storage is unavailable.
    }
  }

  cancel() {
    clearTimeout(this.timer);
    this.generation++;
    this.request?.abort();
    this.request = undefined;
    this.appending = false;
    this.restoring = false;
    this.observer?.disconnect();
    this.root.removeAttribute("aria-busy");
  }

  deactivate() {
    this.save();
    this.cancel();
  }

  activate(
    saved = entries.find((entry) => entry.id === history.state?.[historyKey]),
  ) {
    this.cancel();
    if (saved) {
      const renderedSignature = this.region.dataset.searchKey || this.signature;
      this.entry = saved;
      this.stopped = saved.stopped;
      this.input.value = saved.q;
      this.sort.value = saved.sort;
      this.explicit = saved.explicit;
      if (this.page !== saved.page || renderedSignature !== this.signature) {
        void this.restore(saved);
        return;
      }
    }
    this.region.dataset.searchKey = this.signature;
    this.controls();
    if (saved) {
      this.restoring = true;
      this.scroll(saved.scroll, () => {
        this.restoring = false;
        this.save();
        this.observe();
      });
    } else {
      this.observe();
      this.save();
    }
  }

  private scroll(top: number, restored?: () => void) {
    const generation = this.generation;
    requestAnimationFrame(() =>
      requestAnimationFrame(() => {
        if (this.root.isConnected && active === this && generation === this.generation) {
          window.scrollTo(0, top);
          restored?.();
        }
      }),
    );
  }

  private controls() {
    this.sort.dataset.autoSort = String(!this.explicit);
    const automatic =
      this.sort.querySelector<HTMLOptionElement>('option[value=""]');
    const effective = this.sort.querySelector<HTMLOptionElement>(
      this.input.value.trim()
        ? 'option[value="relevance"]'
        : 'option[value="newest"]',
    );
    if (automatic && effective) {
      automatic.textContent = `${automatic.textContent?.split(":")[0]}: ${effective.textContent}`;
    }
    this.form
      .querySelectorAll<
        HTMLInputElement | HTMLSelectElement | HTMLButtonElement
      >("input, select, button")
      .forEach((control) => {
        control.disabled = this.fallback;
      });
  }

  private edit(immediate: boolean) {
    this.cancel();
    this.pending = true;
    this.stopped = false;
    if (!this.explicit) {
      this.sort.value = "";
    }
    this.controls();
    const url = new URL(this.form.action, location.href);
    const q = this.input.value.trim();
    if (q) url.searchParams.set("q", q);
    else url.searchParams.delete("q");
    if (this.explicit) url.searchParams.set("sort", this.sort.value);
    else url.searchParams.delete("sort");
    url.hash = "";
    history.replaceState(
      { ...history.state, [historyKey]: this.entry.id },
      "",
      url,
    );
    try {
      // Keep HTMX's snapshot URL aligned with replace-only live search edits.
      sessionStorage.setItem(
        "htmx-current-path-for-history",
        url.pathname + url.search,
      );
    } catch {
      // A cache miss is reconstructed from entry metadata instead.
    }
    this.save();
    if (immediate) void this.replace();
    else
      this.timer = setTimeout(() => {
        void this.replace();
      }, 300);
  }

  private async fetchPage(page: number, generation: number) {
    this.request = new AbortController();
    const url = new URL("/browse/results", location.origin);
    const q = this.input.value.trim();
    if (q) url.searchParams.set("q", q);
    if (this.explicit) url.searchParams.set("sort", this.sort.value);
    url.searchParams.set("page", String(page));
    const response = await fetch(url, {
      signal: this.request.signal,
      credentials: "same-origin",
      headers: { Accept: "text/html" },
    });
    const document = new DOMParser().parseFromString(
      await response.text(),
      "text/html",
    );
    if (generation !== this.generation || !this.root.isConnected) return;
    const region = document.querySelector<HTMLElement>("#browse-results");
    if (!region || !["search", "fallback", "error"].includes(region.dataset.kind || "")) {
      throw new Error("Missing or invalid browse results");
    }
    if (!response.ok && region.dataset.kind !== "error")
      throw new Error("Browse request failed");
    region.dataset.searchKey = this.signature;
    return region;
  }

  private install(region: HTMLElement, append: boolean) {
    region.querySelector("[data-browse-status]")?.remove();
    if (
      append &&
      region.dataset.fallback !== "true" &&
      region.dataset.kind !== "fallback"
    ) {
      const items = this.region.querySelector(itemsSelector);
      const incoming = region.querySelector(itemsSelector);
      if (!items || !incoming) throw new Error("Missing browse items");
      const ids = new Set(
        Array.from(items.querySelectorAll("[data-recipe-id]"), (item) =>
          item.getAttribute("data-recipe-id"),
        ),
      );
      for (const item of Array.from(incoming.children)) {
        const id = item.getAttribute("data-recipe-id");
        if (!id || !ids.has(id)) {
          items.append(item);
          if (id) ids.add(id);
        }
      }
      Object.assign(this.region.dataset, region.dataset);
      const oldMore = this.region.querySelector(moreSelector);
      (oldMore?.closest("nav") || oldMore)?.remove();
      this.region
        .querySelectorAll("[data-sentinel]")
        .forEach((sentinel) => sentinel.remove());
      const more = region.querySelector(moreSelector);
      if (more) this.region.append(more.closest("nav") || more);
      const sentinel = region.querySelector("[data-sentinel]");
      if (sentinel) this.region.append(sentinel);
    } else {
      this.region.replaceWith(region);
    }
    this.controls();
    const htmx = (window as Window & {
      htmx?: { process(element: Element): void };
    }).htmx;
    htmx?.process(this.region);
  }

  private async replace() {
    const generation = this.generation;
    this.root.setAttribute("aria-busy", "true");
    this.status("Rezepte werden gesucht…");
    try {
      const region = await this.fetchPage(1, generation);
      if (!region) return;
      this.install(region, false);
      this.pending = false;
      this.stopped = this.region.dataset.kind === "error";
      this.status(
        this.stopped
          ? errorMessage
          : this.fallback
            ? fallbackMessage
            : this.resultMessage(),
      );
      this.save();
    } catch {
      if (generation !== this.generation) return;
      this.stopped = true;
      this.clearResults();
      this.status(errorMessage);
      this.save();
    } finally {
      if (generation === this.generation) {
        this.request = undefined;
        this.root.removeAttribute("aria-busy");
        this.observe();
      }
    }
  }

  private clearResults() {
    this.pending = false;
    this.region.querySelector(itemsSelector)?.replaceChildren();
    this.region
      .querySelectorAll(`${moreSelector}, [data-sentinel]`)
      .forEach((element) => element.remove());
    Object.assign(this.region.dataset, {
      kind: "error",
      fallback: "false",
      page: "1",
      found: "0",
      query: this.input.value.trim(),
      sort: this.explicit ? this.sort.value : "",
      searchKey: this.signature,
    });
    this.controls();
  }

  private hasMore() {
    return (
      !this.fallback &&
      this.page * Number(this.region.dataset.perPage) <
        Number(this.region.dataset.found)
    );
  }

  private resultMessage() {
    return Number(this.region.dataset.found) === 0
      ? "Keine Rezepte gefunden."
      : `${this.region.dataset.found} Rezepte gefunden.`;
  }

  private observe() {
    this.observer?.disconnect();
    const more = this.region.querySelector<HTMLElement>(moreSelector);
    if (more) {
      more.hidden = this.pending || !this.hasMore();
      more.removeAttribute("aria-disabled");
    }
    if (
      !more ||
      this.stopped ||
      this.pending ||
      !this.hasMore() ||
      !("IntersectionObserver" in window)
    )
      return;
    this.observer = new IntersectionObserver((records) => {
      if (records.some((record) => record.isIntersecting)) void this.append();
    });
    this.observer.observe(this.region.querySelector("[data-sentinel]") || more);
  }

  private async append() {
    if (
      this.appending ||
      this.restoring ||
      this.pending ||
      this.request ||
      !this.hasMore()
    )
      return;
    const generation = this.generation;
    this.appending = true;
    this.observer?.disconnect();
    this.root.setAttribute("aria-busy", "true");
    this.status("Weitere Rezepte werden geladen…");
    try {
      const region = await this.fetchPage(this.page + 1, generation);
      if (!region) return;
      if (region.dataset.kind === "error")
        throw new Error("Browse page failed");
      this.install(region, true);
      this.stopped = false;
      this.status(
        this.fallback
          ? fallbackMessage
          : this.hasMore()
            ? "Weitere Rezepte geladen."
            : "Alle Rezepte geladen.",
      );
      this.save();
    } catch {
      if (generation !== this.generation) return;
      this.stopped = true;
      this.status(errorMessage);
      this.save();
    } finally {
      if (generation === this.generation) {
        this.request = undefined;
        this.appending = false;
        this.root.removeAttribute("aria-busy");
        this.observe();
      }
    }
  }

  private async restore(saved: BrowseEntry) {
    this.restoring = true;
    const generation = this.generation;
    let restoredPage = 0;
    let failed = false;
    this.root.setAttribute("aria-busy", "true");
    this.status("Rezepte werden wiederhergestellt…");
    try {
      for (let page = 1; page <= saved.page; page++) {
        const region = await this.fetchPage(page, generation);
        if (!region) return;
        if (region.dataset.kind === "error")
          throw new Error("Browse restoration failed");
        this.install(region, page > 1);
        restoredPage = page;
        if (!this.hasMore()) break;
      }
      this.pending = false;
      this.scroll(saved.scroll);
      this.status(this.fallback ? fallbackMessage : this.resultMessage());
    } catch {
      if (generation === this.generation) {
        failed = true;
        this.stopped = true;
        if (restoredPage === 0) this.clearResults();
        this.status(errorMessage);
      }
    } finally {
      if (generation === this.generation) {
        this.restoring = false;
        if (failed) this.save();
        this.request = undefined;
        this.root.removeAttribute("aria-busy");
        this.observe();
      }
    }
  }
}

function initialize(restore = false) {
  const freshDocument = !documentInitialized;
  documentInitialized = true;
  const root = document.querySelector<HTMLElement>(rootSelector);
  if (active && active.root !== root) {
    active.deactivate();
    active = undefined;
  }
  if (
    !root ||
    !root.querySelector("form [name=q]") ||
    !root.querySelector("form [name=sort]") ||
    !root.querySelector(regionSelector)
  )
    return;
  const existing = controllers.get(root);
  if (existing) {
    if (active === existing && !restore) return;
    active = existing;
    existing.activate();
  } else {
    active = new BrowseSearch(root, freshDocument);
    controllers.set(root, active);
  }
}

document.addEventListener("htmx:beforeHistorySave", () => active?.save());
document.addEventListener("htmx:beforeSwap", (event) => {
  if ((event as CustomEvent).detail?.target?.contains(active?.root))
    active?.deactivate();
});
document.addEventListener("htmx:afterSettle", () => initialize());
document.addEventListener("htmx:historyRestore", () => initialize(true));
window.addEventListener("pagehide", () => active?.deactivate());
window.addEventListener("pageshow", (event) => initialize(event.persisted));
window.addEventListener("scroll", () => active?.save(), { passive: true });
if (!customElements.get("browse-search")) {
  customElements.define("browse-search", class extends HTMLElement {});
}
if (document.readyState === "loading")
  document.addEventListener("DOMContentLoaded", () => initialize());
else initialize();
