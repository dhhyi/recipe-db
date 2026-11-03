# Design

Shared UI component library, implemented using [Lit](https://lit.dev/) web components with [Blades CSS](https://blades.ninja/) and spacing/layout tools from [Tailwind CSS](https://tailwindcss.com/), documented in [Storybook](https://storybook.js.org/).

## Storybook

Use Storybook's theme switch to review every story in light and dark mode. Do not create dedicated light/dark stories or hard-code a theme in a story; stories should describe distinct component states and follow the selected theme.

## Form labels

- Do not use floating labels or visible labels above text-like inputs (`text`, `url`, `search`).
- Text-like inputs show their hint as a `placeholder` and set the same text as `aria-label`.
- File inputs may keep a visible `<label for>`, since they cannot show a placeholder.
- A textarea directly below a section heading uses only `aria-label`; the heading is its visible hint.
- Selects use `aria-label`; the selected option is their visible hint.

## Actions and navigation

- Each page, or self-contained context within it such as a dialog or panel, has at most one primary action, shown as a button.
- A page has at most one back-navigation action, shown as a link. It goes up one level in the hierarchy to a fixed target, not via browser history.
- A page can have multiple secondary actions.
- Links navigate (a GET without side effects); buttons perform actions (submit, save, toggle, delete), even when a redirect follows.

## Button styles

- Primary actions use the default Blades button (solid fill in the primary color).
- Secondary actions use the Blades `outline` button (primary color for text and border, no fill).
- Do not use the Blades `secondary` or `contrast` button classes. The only exception is the file input's button, which `design.css` styles as a secondary outline button.
- All buttons, including link and dropdown buttons (`role="button"`), use the default Blades font weight. Do not make button text bold.

## Links

- Links use the default Blades link (primary color).
- Links are not underlined at rest; the underline appears only on hover, active, and focus (set globally in `design.css`).
- Footer links use the Blades `secondary` link class. Do not use `secondary` links elsewhere, and do not use `contrast` links.
- Footer links are low-priority meta links, so their reduced light-theme contrast (about 2.7:1 against white, below WCAG AA) is accepted. Do not use the `secondary` link color for content or navigation that users need.

## Feedback

- Messages about the outcome of an action or the state of loaded content use the `feedback` classes defined in `design.css`, combined with `role="status"` or `role="alert"`:
  - `feedback success` (Pico `--pico-ins-color`): an action succeeded, for example "Gespeichert".
  - `feedback warning` (`--feedback-warning-color`, our own color because Blades has none): the action works, but the result has a drawback, or there are unsaved changes.
  - `feedback error` (Pico `--pico-del-color`): an action, loading, or access failed, or content was not found. Include what is preserved for a retry in the same message.
- Do not show neutral state messages such as "Keine ungespeicherten Änderungen."
- Form field validation uses the Blades `aria-invalid` styling with a helper `<small>`, not `feedback`.

## Loading

- The Blades spinner (`aria-busy="true"`) is the only loading indicator. Do not show loading status texts.
- An action triggered by a button sets `aria-busy` on that button only and disables it. Other controls that could start a conflicting request are disabled too, without a spinner.
- Button labels do not change while loading. The only allowed label change is to a retry wording ("Erneut speichern", "Erneut versuchen") after a failure.
- Content that is loading, or that loads when scrolled into view, is an empty spinner placeholder in its place, with an `aria-label` describing what is loading (for example `aria-label="Rezept wird geladen"`), without an ellipsis.
- A placeholder must handle errors: on failure, it is replaced by a `feedback error` message and an `Erneut versuchen` button, which follows the button rule above.
- Spinner placeholders have no no-JavaScript fallback; see #150.

## App-specific styles

Shared look and feel (colors, buttons, links, feedback, typography) lives in `design.css`. Apps may keep CSS for components that only they use, such as the image editor's crop area, but must not restyle or extend shared elements locally.

## Tailwind CSS

The shared `design` project builds the Tailwind stylesheet used by frontend projects. A frontend that loads `/design/styles.css` declares the files or directories containing its utility classes with `tailwindSources` in the second document of its `.project.yaml`.

The Tailwind CSS IntelliSense extension is installed in each frontend devcontainer and configured to use `design/src/design.css`, so no copied Tailwind configuration is necessary.
