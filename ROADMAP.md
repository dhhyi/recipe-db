# Roadmap

## Get rid of most JavaScript

I deal with TypeScript/JavaScript enough in my daily work, so I want to minimize its presence in this project as much as possible. It shouldn't be used as a project base.

It is okay for the design project using Storybook, and web-components that are shared between different parts of the application.

It's also allowed for frontends compiled to JavaScript, like Elm (images-edit) and ClojureScript (recipes-edit), since JavaScript is merely the output, but not the language used for development.

### Replace JavaScript build tools

JavaScript build tooling (root-level, .scripts folder) will be replaced with Bazel build rules and native toolchain integrations.

#### Rework docker-compose/deployment generation

> **Status:** Compose templating is complete. The old JavaScript generator has been replaced by a
> shell/yq/jq data-preparation step and ytt templates for development and production Compose output,
> including the production `traefik.yml`. The later Kubernetes/k3s and k3d deployment work remains
> open.

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

### Better image editor

The images frontend should be the only place where the full-size image is loaded, along with a crop overlay that lets the user select the crop area.

## Raspberry Pi deployment

### Check for ARM64 build

Check that all production images can be built for ARM.

### Protect web frontend with login mechanism

The web frontend should be protected with a login mechanism, so that it is not publicly accessible. This should either be simple HTTP basic auth or a more complex solution with OAuth via Google.

### Setup Raspberry Pi deployment

Explore the possibility of deploying the stack on a Raspberry Pi with either Kubernetes or Docker Compose.
Setup a public deployment.

## Ideas for other services:

### Tags

TBA, maybe graph database?

Specific tags for:

- Country
- Vegetarian/Vegan/Pescetarian
- Main/Side/Appetizer/Dessert

### Add to shopping list

[Bring!](https://www.getbring.com/) integration.

### Comments

graph-like data structure

### Food diary

User can track when he had a certain recipe.

### Relations

- Variant of
- Side dish

### Collections

Add recipes to collections (public and private)

### Recipe State

(should really be part of recipe data)

- public
- draft
- idea

## Cross Concerns

### Authentication

Probably [Google oAuth via traefik](https://www.libe.net/traefik-auth).

### searching

Maybe with [OpenSearch](https://opensearch.org/docs/latest/) or [Quickwit](https://quickwit.io/docs/get-started/quickstart).

- by name
- by rating for user
- recipes containing ingredient/tag

### Caching and updating

Message queue notify on update -> pre-render and cache page again.

### Resilience

Maybe later.

## Misc
