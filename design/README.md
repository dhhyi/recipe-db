# Design

Shared UI component library, implemented using [Lit](https://lit.dev/) web components with [Blades CSS](https://blades.ninja/) and spacing/layout tools from [Tailwind CSS](https://tailwindcss.com/), documented in [Storybook](https://storybook.js.org/).

## Tailwind CSS

The shared `design` project builds the Tailwind stylesheet used by frontend
projects. A frontend that loads `/design/styles.css` declares the files or
directories containing its utility classes with `tailwindSources` in the second
document of its `.project.yaml`. Run `pnpm synchronize` after changing those
sources; it generates the ignored `design/src/tailwind-sources.css` manifest
used by the Vite build.

The Tailwind CSS IntelliSense extension is installed in each frontend
devcontainer and configured to use `design/src/design.css`, so no copied
Tailwind configuration is necessary.
