# Roadmap

## Get rid of most JavaScript

I deal with TypeScript/JavaScript enough in my daily work, so I want to minimize its presence in this project as much as possible. It shouldn't be used as a project base.

It is okay for the design project using Storybook, and web-components that are shared between different parts of the application.

It's also allowed for the Elm images-edit frontend, since JavaScript is merely the output, but not the language used for development.

### Replace Astro frontend

The Astro frontend will be replaced with Go + templ + HTMX.

### Replace Apollo GraphQL

The Apollo GraphQL server will be replaced with a solution based on Elixir+Absinthe.

### Replace link-extract Deno application

This application will be replaced with a different solution.

### Replace JavaScript build tools

JavaScript build tooling (root-level, .scripts folder) will be replaced with Bazel build rules and native toolchain integrations.

## Make a pretty frontend

The frontend should have a consistent and visually appealing design, leveraging the shared UI component library implemented with Lit web components, Blades CSS, and Tailwind CSS for spacing and layout. Storybook will be used for documenting and testing the components.

### Frontend styling

When replacing Astro with Go + templ + HTMX, repair the frontend styling
and apply the shared component library.

### Accessibility structure

Give every user-facing page a page-specific `<h1>` inside a `<main>` landmark,
with matching, route-specific document titles. Keep “Rezeptdatenbank” as a
shared linked brand rather than a heading. Apply this consistently to the
overview, recipe detail, image editor, and replacement recipe editor; render
loading, success, and error feedback as live status messages instead of
headings.

Examples:

- Overview: `<title>Alle Rezepte | RezeptDB</title>` and `<h1>Alle Rezepte</h1>`
- Recipe detail: `<title>Milchreis | RezeptDB</title>` and `<h1>Milchreis</h1>`
- Image editor: `<title>Bild für Milchreis bearbeiten | RezeptDB</title>` and
  `<h1>Bild für Milchreis bearbeiten</h1>`

### Image editor

The image editor is intentionally simple now. Add only the shared UI header;
otherwise, it is complete.

### Recipe editor

Replace `recipes-edit`, which is runtime-heavy and difficult to customize,
with an editor based on [Sky](https://sky-lang.org/).
