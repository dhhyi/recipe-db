import "./components/header.ts";
import "./components/footer.ts";
import "./components/rating.ts";
import "./components/recipe-tile.ts";
import "./components/recipe-image-carousel.ts";
import "./components/recipe-chevron.ts";

document.addEventListener("htmx:beforeTransition", (event) => {
  if (!(event.target instanceof Element)) {
    return;
  }
  if (event.target.closest("form[data-tag-mutation], #recipe-tag-search")) {
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
  const tile = event.target.closest("recipe-tile-component");
  if (tile && event.target.closest("a[hx-boost]")) {
    if (
      !("activeViewTransition" in document) ||
      !CSS.supports("selector(:active-view-transition-type(recipe-open))")
    ) {
      event.preventDefault();
      return;
    }
    tile.setAttribute("data-transition-selected", "");
    queueMicrotask(() => {
      const transition = document.activeViewTransition;
      if (!transition) {
        tile.removeAttribute("data-transition-selected");
        return;
      }
      transition.types.add("recipe-open");
      void transition.finished.then(
        () => tile.removeAttribute("data-transition-selected"),
        () => tile.removeAttribute("data-transition-selected"),
      );
    });
    return;
  }
  if (!event.target.closest("a[data-browse-home]")) {
    return;
  }
  const fromBrowse = document.querySelector("#browse-content") !== null;
  const type = fromBrowse ? "browse-results" : "browse-home";
  if (
    (fromBrowse && !location.search) ||
    !("activeViewTransition" in document) ||
    !CSS.supports(`selector(:active-view-transition-type(${type}))`)
  ) {
    event.preventDefault();
    return;
  }
  // HTMX starts the transition after this event, before the queued microtask.
  queueMicrotask(() => document.activeViewTransition?.types.add(type));
});
