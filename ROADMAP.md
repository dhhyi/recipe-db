# Roadmap

## Get rid of most JavaScript

I deal with TypeScript/JavaScript enough in my daily work, so I want to minimize its presence in this project as much as possible. It shouldn't be used as a project base.

It is okay for the design project using Storybook, and web-components that are shared between different parts of the application.

It's also allowed for the Elm images-edit frontend, since JavaScript is merely the output, but not the language used for development.

### Replace Apollo GraphQL

The Apollo GraphQL server will be replaced with a solution based on Elixir+Absinthe.

### Replace link-extract Deno application

This application will be replaced with a different solution.

### Replace JavaScript build tools

JavaScript build tooling (root-level, .scripts folder) will be replaced with Bazel build rules and native toolchain integrations.

## Make a pretty frontend

The frontend should have a consistent and visually appealing design, leveraging the shared UI component library implemented with Lit web components, Blades CSS, and Tailwind CSS for spacing and layout. Storybook will be used for documenting and testing the components.

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

### Recipe editor

Replace `recipes-edit`, which is runtime-heavy and difficult to customize,
with an editor based on [Sky](https://sky-lang.org/).

## Image handling

### More specific image information

Image metadata from the images backend should include width, height, and aspect ratio so that the frontend can render images with the correct aspect ratio without loading the image first.
Thumbnails are now used by default and have a width of 650px, which is arguably too large for a thumbnail. For overview pages, a thumbnail width of 300px is more appropriate.

### Better image editor

The images frontend should be the only place where the full-size image is loaded, along with a crop overlay that lets the user select the crop area.

### Placeholder images

Frontend apps that load images should use a correctly sized placeholder while loading and also support a placeholder when an image is unavailable. The placeholder could be a blurred version of the image, and it can later be replaced with a higher-quality version once the image is scrolled into view.
