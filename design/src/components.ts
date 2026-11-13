import "./components/header.ts";
import "./components/footer.ts";
import "./components/rating.ts";
import "./components/recipe-tile.ts";

let historyTransition:
  "browse-return" | "browse-results" | "history-page" | undefined;

// HTMX exposes the history swap spec immediately before performing the swap.
for (const name of ["htmx:historyCacheHit", "htmx:historyCacheMissLoad"]) {
  document.addEventListener(name, (event) => {
    if (
      !(event instanceof CustomEvent) ||
      typeof event.detail?.path !== "string" ||
      typeof event.detail?.swapSpec !== "object" ||
      event.detail.swapSpec === null
    ) {
      return;
    }
    const destination = new URL(event.detail.path, location.href);
    historyTransition =
      destination.pathname === "/" && document.querySelector(".recipe-image")
        ? "browse-return"
        : destination.pathname === "/" &&
            document.querySelector("#browse-content")
          ? "browse-results"
          : "history-page";
    event.detail.swapSpec.transition = true;
    queueMicrotask(() => {
      historyTransition = undefined;
    });
  });
}

document.addEventListener("htmx:beforeTransition", (event) => {
  if (historyTransition) {
    const type = historyTransition;
    historyTransition = undefined;
    if (
      !("activeViewTransition" in document) ||
      !CSS.supports(`selector(:active-view-transition-type(${type}))`)
    ) {
      event.preventDefault();
    } else {
      queueMicrotask(() => document.activeViewTransition?.types.add(type));
    }
    return;
  }
  if (
    event.target instanceof Element &&
    event.target.closest("form[data-tag-mutation], #recipe-tag-search")
  ) {
    const type = event.target.closest("#recipe-tag-search")
      ? "tag-search"
      : "tag-edit";
    if (
      !("activeViewTransition" in document) ||
      !CSS.supports(`selector(:active-view-transition-type(${type}))`)
    ) {
      event.preventDefault();
      return;
    }
    queueMicrotask(() => document.activeViewTransition?.types.add(type));
    return;
  }
  if (
    !(event.target instanceof Element) ||
    !event.target.closest("a[data-browse-home]")
  ) {
    return;
  }
  const fromBrowse = document.querySelector("#browse-content") !== null;
  if (
    (fromBrowse && !location.search) ||
    !("activeViewTransition" in document) ||
    !CSS.supports("selector(:active-view-transition-type(browse-return))")
  ) {
    event.preventDefault();
    return;
  }
  // HTMX starts the transition after this event, before the queued microtask.
  queueMicrotask(() =>
    document.activeViewTransition?.types.add(
      fromBrowse ? "browse-results" : "browse-return",
    ),
  );
});
