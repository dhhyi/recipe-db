# Roadmap

## Get rid of most JavaScript

I deal with TypeScript/JavaScript enough in my daily work, so I want to minimize its presence in this project as much as possible. It shouldn't be used as a project base.

It is okay for the design project using Storybook, and web-components that are shared between different parts of the application.

It's also allowed for frontends compiled to JavaScript, like Elm (images-edit) and ClojureScript (recipes-edit), since JavaScript is merely the output, but not the language used for development.

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

#### Rework docker-compose/deployment generation

`generate-docker-compose.js` currently mixes several concerns in one script: reading each project's
`.project.yaml` traefik section, aggregating it into the production `traefik.yml`, and rendering the
full `docker-compose.yml` (service definitions, profiles, depends_on, dev/prod differences) in a
single pass. Its replacement should be a proper templating mechanism instead, using **ytt** (a
single-binary, no-runtime-deps templating/overlay tool for YAML; CUE and jsonnet are more powerful
but heavier alternatives if ytt turns out too limited): a docker-compose service template populated
from the traefik/service data in `.project.yaml`, rendered per flavour (development, production).

Local dev stays on docker-compose regardless of what happens to production: the current setup's best
feature is that a devcontainer carries the exact same Traefik labels as the production service, so
opening it in VS Code just swaps it into the already-running stack on the shared Docker network —
zero extra steps. That's worth more than any Kubernetes benefit for local dev.

For production, go full Kubernetes (k3s, matching the Raspberry Pi target) instead of also supporting
docker-compose there — plus k3d as a local stand-in for testing the production k3s setup itself
(not for day-to-day service development, which stays docker-compose). Low-priority note: Kubernetes
has an equivalent of the devcontainer-swap workflow, called service "interception", via tools like
Telepresence or mirrord, which reroute a running service's traffic to a local process/container while
the rest of the cluster keeps running — but it needs a cluster-side agent plus a local tunnel/daemon
per intercepted service, so it's not worth chasing unless the docker-compose dev setup becomes
untenable.

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

### Rewrite recipe backend

Since currently both `frontend` and `recipes` is written in Go, it violates the playground rule to have another language for each project. Find a good language that can be used for the recipe backend, and rewrite it in that language. The new language should be one that is not already used in the project, and should be suitable for receiving json data and querying them by ID.
