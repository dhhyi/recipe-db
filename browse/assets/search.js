const historyKey = "__browseSearch";
const storageKey = "recipe-db:browse-history";
const errorMessage = "Rezepte konnten nicht geladen werden.";
const fallbackMessage = "Suche nicht verfügbar. Alle Rezepte werden angezeigt.";
const controllers = new WeakMap();
let active;
let documentInitialized = false;

function readEntries() {
  try {
    const entries = JSON.parse(sessionStorage.getItem(storageKey) || "[]");
    return Array.isArray(entries)
      ? entries
          .filter(
            (entry) =>
              typeof entry?.id === "string" &&
              typeof entry.q === "string" &&
              typeof entry.sort === "string" &&
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
  generation = 0;
  composing = false;
  stopped = false;
  restoring = false;
  pending = false;

  constructor(root, freshDocument) {
    this.root = root;
    this.form = root.querySelector("form");
    this.input = this.form.elements.q;
    this.sort = this.form.elements.sort;
    let saved = entries.find(
      (entry) => entry.id === history.state?.[historyKey],
    );
    const navigation = performance.getEntriesByType("navigation")[0];
    if (freshDocument && saved && navigation?.type !== "back_forward") {
      saved = {
        ...saved,
        q: this.input.value,
        sort: this.sort.value,
        page: 1,
        scroll: 0,
        stopped: false,
      };
    }
    this.entry = saved || {
      id: Array.from(crypto.getRandomValues(new Uint32Array(4)), (value) =>
        value.toString(16),
      ).join("-"),
      q: this.input.value,
      sort: this.sort.value,
      page: this.page,
      scroll: scrollY,
      stopped: false,
    };
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
      if (!this.composing && !event.isComposing) this.edit(false);
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
      if (!this.composing) this.edit(true);
    });
    this.root.addEventListener("click", (event) => {
      if (event.target.closest("[data-load-more]")) {
        event.preventDefault();
        void this.load("append");
      }
    });
    this.activate(saved);
  }

  get region() {
    return this.root.querySelector("#browse-results");
  }

  get page() {
    return Number(this.region.dataset.page) || 1;
  }

  get fallback() {
    return this.region.dataset.kind === "fallback";
  }

  get signature() {
    return JSON.stringify([this.input.value.trim(), this.sort.value]);
  }

  status(message) {
    this.root.querySelector("[data-browse-status]").textContent = message;
  }

  save() {
    if (this.restoring || this.composing || !this.root.isConnected) return;
    this.entry = {
      ...this.entry,
      q: this.input.value,
      sort: this.sort.value,
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
      if (this.page !== saved.page || renderedSignature !== this.signature) {
        void this.load("restore", saved);
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

  scroll(top, restored) {
    const generation = this.generation;
    requestAnimationFrame(() =>
      requestAnimationFrame(() => {
        if (
          this.root.isConnected &&
          active === this &&
          generation === this.generation
        ) {
          window.scrollTo(0, top);
          restored?.();
        }
      }),
    );
  }

  controls() {
    const automatic = this.sort.querySelector('option[value=""]');
    const effective = this.sort.querySelector(
      this.input.value.trim()
        ? 'option[value="relevance"]'
        : 'option[value="newest"]',
    );
    if (automatic && effective) {
      automatic.textContent = `${automatic.textContent?.split(":")[0]}: ${effective.textContent}`;
    }
    this.form.querySelectorAll("input, select, button").forEach((control) => {
      control.disabled = this.fallback;
    });
  }

  edit(immediate) {
    this.cancel();
    this.pending = true;
    this.stopped = false;
    this.controls();
    const url = new URL(this.form.action, location.href);
    const q = this.input.value.trim();
    if (q) url.searchParams.set("q", q);
    else url.searchParams.delete("q");
    if (this.sort.value) url.searchParams.set("sort", this.sort.value);
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
    if (immediate) void this.load("replace");
    else
      this.timer = setTimeout(() => {
        void this.load("replace");
      }, 300);
  }

  async fetchPage(page, generation) {
    this.request = new AbortController();
    const url = new URL("/browse/results", location.origin);
    const q = this.input.value.trim();
    if (q) url.searchParams.set("q", q);
    if (this.sort.value) url.searchParams.set("sort", this.sort.value);
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
    const region = document.querySelector("#browse-results");
    if (
      !region ||
      !["search", "fallback", "error"].includes(region.dataset.kind || "")
    ) {
      throw new Error("Missing or invalid browse results");
    }
    if (!response.ok && region.dataset.kind !== "error")
      throw new Error("Browse request failed");
    region.dataset.searchKey = this.signature;
    return region;
  }

  install(region, append) {
    region.querySelector("[data-browse-status]")?.remove();
    if (append && region.dataset.kind !== "fallback") {
      const items = this.region.querySelector("[data-recipe-list]");
      const incoming = region.querySelector("[data-recipe-list]");
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
      const oldMore = this.region.querySelector("[data-load-more]");
      (oldMore?.closest("nav") || oldMore)?.remove();
      this.region
        .querySelectorAll("[data-sentinel]")
        .forEach((sentinel) => sentinel.remove());
      const more = region.querySelector("[data-load-more]");
      if (more) this.region.append(more.closest("nav") || more);
      const sentinel = region.querySelector("[data-sentinel]");
      if (sentinel) this.region.append(sentinel);
    } else {
      this.region.replaceWith(region);
    }
    this.controls();
    window.htmx?.process(this.region);
  }

  async load(mode, saved) {
    const append = mode === "append";
    const restoring = mode === "restore";
    if (
      append &&
      (this.restoring || this.pending || this.request || !this.hasMore())
    )
      return;
    const generation = this.generation;
    const firstPage = append ? this.page + 1 : 1;
    const lastPage = restoring ? saved.page : firstPage;
    let installed = false;
    let failed = false;
    this.restoring = restoring;
    this.observer?.disconnect();
    this.root.setAttribute("aria-busy", "true");
    this.status(
      restoring
        ? "Rezepte werden wiederhergestellt…"
        : append
          ? "Weitere Rezepte werden geladen…"
          : "Rezepte werden gesucht…",
    );
    try {
      for (let page = firstPage; page <= lastPage; page++) {
        const region = await this.fetchPage(page, generation);
        if (!region) return;
        if (mode !== "replace" && region.dataset.kind === "error")
          throw new Error("Browse page failed");
        this.install(region, append || page > 1);
        installed = true;
        if (!this.hasMore()) break;
      }
      this.pending = false;
      if (!restoring) this.stopped = this.region.dataset.kind === "error";
      if (restoring) this.scroll(saved.scroll);
      this.status(
        this.region.dataset.kind === "error"
          ? errorMessage
          : this.fallback
            ? fallbackMessage
            : append
              ? this.hasMore()
                ? "Weitere Rezepte geladen."
                : "Alle Rezepte geladen."
              : this.resultMessage(),
      );
    } catch {
      if (generation !== this.generation) return;
      failed = true;
      this.stopped = true;
      if (!append && !installed) this.clearResults();
      this.status(errorMessage);
    } finally {
      if (generation === this.generation) {
        this.restoring = false;
        this.request = undefined;
        this.root.removeAttribute("aria-busy");
        if (!restoring || failed) this.save();
        this.observe();
      }
    }
  }

  clearResults() {
    this.pending = false;
    this.region.querySelector("[data-recipe-list]")?.replaceChildren();
    this.region
      .querySelectorAll("[data-load-more], [data-sentinel]")
      .forEach((element) => element.remove());
    Object.assign(this.region.dataset, {
      kind: "error",
      page: "1",
      found: "0",
      query: this.input.value.trim(),
      sort: this.sort.value,
      searchKey: this.signature,
    });
    this.controls();
  }

  hasMore() {
    return (
      !this.fallback &&
      this.page * Number(this.region.dataset.perPage) <
        Number(this.region.dataset.found)
    );
  }

  resultMessage() {
    return Number(this.region.dataset.found) === 0
      ? "Keine Rezepte gefunden."
      : `${this.region.dataset.found} Rezepte gefunden.`;
  }

  observe() {
    this.observer?.disconnect();
    const more = this.region.querySelector("[data-load-more]");
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
      if (records.some((record) => record.isIntersecting))
        void this.load("append");
    });
    this.observer.observe(this.region.querySelector("[data-sentinel]") || more);
  }
}

function initialize(restore = false) {
  const freshDocument = !documentInitialized;
  documentInitialized = true;
  const root = document.querySelector("[data-browse-search]");
  if (active && active.root !== root) {
    active.deactivate();
    active = undefined;
  }
  if (!root) return;
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
  if (event.detail?.target?.contains(active?.root)) active?.deactivate();
});
document.addEventListener("htmx:afterSettle", () => initialize());
document.addEventListener("htmx:historyRestore", () => initialize(true));
window.addEventListener("pagehide", () => active?.deactivate());
window.addEventListener("pageshow", (event) => initialize(event.persisted));
window.addEventListener("scroll", () => active?.save(), { passive: true });
if (document.readyState === "loading")
  document.addEventListener("DOMContentLoaded", () => initialize());
else initialize();
