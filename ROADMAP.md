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

## Image handling

### More specific image information

Image metadata from the images backend should include width, height, and aspect ratio so that the frontend can render images with the correct aspect ratio without loading the image first.
Thumbnails are now used by default and have a width of 650px, which is arguably too large for a thumbnail. For overview pages, a thumbnail width of 300px is more appropriate.

### Better image editor

The images frontend should be the only place where the full-size image is loaded, along with a crop overlay that lets the user select the crop area.

### Placeholder images

Frontend apps that load images should use a correctly sized placeholder while loading and also support a placeholder when an image is unavailable. The placeholder could be a blurred version of the image, and it can later be replaced with a higher-quality version once the image is scrolled into view.

## Misc

### Devcontainer build caching

Add a `--push-cache` option to Devcontainer Creator. It should build devcontainers with registry `cache-from` and `cache-to`, but must not push the resulting runtime image. Update CI to use this mode, remove the devcontainer image pushes, and delete the existing devcontainer images from GitHub Container Registry while retaining the cache images. Keep the generated `build` configuration locally so local build changes remain visible and can reuse the remote cache.

### better tailwind support

It would be great to use the tailwind VSCode extension in projects to have support for the classes.

it would also be great if the tailwind tree shaking step could be used to minify the resulting style file.

### Recipe update optional

Optional fields in recipe updates should not overwrite if they are not supplied. maybe use PATCH?

### Recipe empty name error

Update with an empty name currently propagates 400 to the client, but it should be proper graphql error that is then displayed by the recipe-edit frontend.
