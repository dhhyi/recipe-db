# Roadmap

## Get rid of most JavaScript

I deal with TypeScript/JavaScript enough in my daily work, so I want to minimize its presence in this project as much as possible. It shouldn't be used as a project base.

It is okay for the design project using Storybook, and web-components that are shared between different parts of the application.

It's also allowed for frontends compiled to JavaScript, like Elm (images-edit) and ClojureScript (recipes-edit), since JavaScript is merely the output, but not the language used for development.

### Replace Apollo GraphQL

The Apollo GraphQL server will be replaced with a solution based on Rust+async-graphql. Query and
mutation fields are merged per domain with `MergedObject`, and the fields that other services
contribute to `Recipe` (rating, image, inspirations) are added via `ComplexObject`. The generated SDL
replaces the hand-written `typedefs.gql` fragments as the source of truth, so
`.scripts/merge-graphql-schemas.js` has to export it from the running schema instead of merging
files. The per-recipe fan-out to the REST backends should use DataLoader to remove the current N+1.

### Rewrite recipes-edit in ClojureScript

recipes-edit is currently the only Rust project, and Rust is needed for the GraphQL server instead.
It will be rewritten as a client-side ClojureScript app served by nginx, mirroring the Elm
images-edit setup. This drops server-side rendering and the Leptos server functions, so the browser
talks to `/graphql` directly.

ClojureScript has no equivalent of `graphql_client`/elm-graphql that turns schema plus operations
into bindings — the ecosystem only offers runtime clients (re-graph) and an operations-only query
builder (graphql-builder). Most of the safety is still recoverable, because ClojureScript macros run
in JVM Clojure at compile time: a macro can validate `operations.graphql` against
`recipe-db.graphqls` with graphql-java and fail the build on schema drift. Together with the GraphQL
LSP, which already checks operations against the copied schema in the editor, only the typed
response shapes are genuinely lost.

### Replace JavaScript build tools

JavaScript build tooling (root-level, .scripts folder) will be replaced with Bazel build rules and native toolchain integrations.

## Image handling

### More specific image information

Image metadata from the images backend should include width, height, and aspect ratio so that the frontend can render images with the correct aspect ratio without loading the image first.
Thumbnails are now used by default and have a width of 650px, which is arguably too large for a thumbnail. For overview pages, a thumbnail width of 300px is more appropriate.

### Better image editor

The images frontend should be the only place where the full-size image is loaded, along with a crop overlay that lets the user select the crop area.

### Placeholder images

Frontend apps that load images should use a correctly sized placeholder while loading and also support a placeholder when an image is unavailable. The placeholder could be a blurred version of the image, and it can later be replaced with a higher-quality version once the image is scrolled into view.

## Raspberry Pi deployment

### Check for ARM64 build

Check that all production images can be built for ARM.

### Protect web frontend with login mechanism

The web frontend should be protected with a login mechanism, so that it is not publicly accessible. This should either be simple HTTP basic auth or a more complex solution with OAuth via Google.

### Setup Raspberry Pi deployment

Explore the possibility of deploying the stack on a Raspberry Pi with either Kubernetes or Docker Compose.
Setup a public deployment.

## Misc

### Devcontainer build caching

Add a `--push-cache` option to Devcontainer Creator. It should build devcontainers with registry `cache-from` and `cache-to`, but must not push the resulting runtime image. Update CI to use this mode, remove the devcontainer image pushes, and delete the existing devcontainer images from GitHub Container Registry while retaining the cache images. Keep the generated `build` configuration locally so local build changes remain visible and can reuse the remote cache.
