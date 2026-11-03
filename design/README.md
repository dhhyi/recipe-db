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

## Tailwind CSS

The shared `design` project builds the Tailwind stylesheet used by frontend projects. A frontend that loads `/design/styles.css` declares the files or directories containing its utility classes with `tailwindSources` in the second document of its `.project.yaml`.

The Tailwind CSS IntelliSense extension is installed in each frontend devcontainer and configured to use `design/src/design.css`, so no copied Tailwind configuration is necessary.
