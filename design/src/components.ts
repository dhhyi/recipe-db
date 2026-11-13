import "./components/header.ts";
import "./components/footer.ts";
import "./components/rating.ts";
import "./components/recipe-tile.ts";

document.addEventListener("htmx:beforeTransition", (event) => {
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
