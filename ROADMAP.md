# Roadmap

## Get rid of most JavaScript

I deal with TypeScript/JavaScript enough in my daily work, so I want to minimize its presence in this project as much as possible. It shouldn't be used as a project base.

It is okay for the design project using Storybook, and web-components that are shared between different parts of the application.

It's also allowed for frontends compiled to JavaScript, like Elm (images-edit) and ClojureScript (recipes-edit), since JavaScript is merely the output, but not the language used for development.

### Replace JavaScript build tools

JavaScript build tooling (root-level, .scripts folder) will be replaced with Bazel build rules and native toolchain integrations.

#### Rework docker-compose/deployment generation

> **Status:** Compose templating is complete. The old JavaScript generator has been replaced by a shell/yq/jq data-preparation step and ytt templates for development and production Compose output, including the production `traefik.yml`. The later Kubernetes/k3s and k3d deployment work remains open.

`generate-docker-compose.js` currently mixes several concerns in one script: reading each project's `.project.yaml` traefik section, aggregating it into the production `traefik.yml`, and rendering the full `docker-compose.yml` (service definitions, profiles, depends_on, dev/prod differences) in a single pass. Its replacement should be a proper templating mechanism instead, using **ytt** (a single-binary, no-runtime-deps templating/overlay tool for YAML; CUE and jsonnet are more powerful but heavier alternatives if ytt turns out too limited): a docker-compose service template populated from the traefik/service data in `.project.yaml`, rendered per flavour (development, production).

Local dev stays on docker-compose regardless of what happens to production: the current setup's best feature is that a devcontainer carries the exact same Traefik labels as the production service, so opening it in VS Code just swaps it into the already-running stack on the shared Docker network — zero extra steps. That's worth more than any Kubernetes benefit for local dev.

For production, go full Kubernetes (k3s, matching the Raspberry Pi target) instead of also supporting docker-compose there — plus k3d as a local stand-in for testing the production k3s setup itself (not for day-to-day service development, which stays docker-compose). Low-priority note: Kubernetes has an equivalent of the devcontainer-swap workflow, called service "interception", via tools like Telepresence or mirrord, which reroute a running service's traffic to a local process/container while the rest of the cluster keeps running — but it needs a cluster-side agent plus a local tunnel/daemon per intercepted service, so it's not worth chasing unless the docker-compose dev setup becomes untenable.

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

Explore graph databases as a way to model recipe tags and relationships.

Recipe owners can assign multiple descriptive tags, organized into categories such as:

- Cuisine (e.g. Japanese, Mexican)
- Dietary style (e.g. vegetarian, vegan, pescetarian)
- Course (e.g. main, side, appetizer, dessert)

Tags should be searchable when recipe search is implemented. Explore finding similar recipes by traversing shared tags, and later by adding relationships such as related cuisines, shared ingredients, or recipe variants.

Use this as a practical graph-database experiment: evaluate how well it supports tagging and relationship queries, as well as its operational fit for the project.

### Add to shopping list

[Bring!](https://www.getbring.com/) integration — an "add ingredients to my shopping list" button on the recipe page.

Bring! offers two fundamentally different paths:

**A) Official recipe import (parser-based, no account needed on our side).** Bring!'s servers fetch a recipe URL, parse [schema.org/Recipe](https://schema.org/Recipe) markup out of it (`name`, `recipeIngredient`, `recipeYield`, `image`, ...) and open the app with the ingredients pre-filled. Two integration flavours, both documented in the official [Bring! Import Developer Guide](https://sites.google.com/getbring.com/bring-import-dev-guide/web-to-app-integration):

- JS widget: `<script async src="//platform.getbring.com/widgets/import.js">` plus a `<div data-bring-import data-bring-language data-bring-theme data-bring-base-quantity>` element; supports `window.bringwidgets.import.setRequestedQuantity(n)` for a portion scaler.
- Plain link (no JavaScript, preferable here): `https://api.getbring.com/rest/bringrecipes/deeplink?url=<urlencoded recipe url>&source=web&baseQuantity=4&requestedQuantity=4` — answers `307` with the app deeplink in `Location`. A `POST` variant returning `{"deeplink": "..."}` exists too ([App-to-App guide](https://sites.google.com/getbring.com/bring-import-dev-guide/app-to-app-integration)).

Prerequisite work is small: `frontend` already emits schema.org microdata — `detail.templ` wraps the page in `itemscope itemtype="https://schema.org/Recipe"` with `itemprop="name"`, `image`, `recipeIngredient` and `recipeInstructions`, `overview.templ` marks up the tiles, and `rating.templ` adds an `AggregateRating`. Gaps to close for Bring!: there is no `recipeYield`, so the portion scaler would have to fall back to `baseQuantity` on the link; and `recipeIngredient` sits on the `<tr>` whose amount/unit/name are split across two `<td>`s, so the parsed text needs checking (Bring! splits an ingredient string into `itemId` + `spec` itself). Run the page through [getbring.com/en/integration-check](https://www.getbring.com/en/integration-check) to see what the parser actually extracts before changing anything.

Hard constraint: Bring!'s parser must be able to fetch the recipe page from the public internet, which collides with the planned "protect web frontend with login mechanism" item above. Mitigations to explore: a per-recipe unguessable public "share" URL exempted from auth that renders only the microdata/ingredients, or pointing `url=` at a `.json` file (the guide supports it, but explicitly discourages it and loses icon auto-assignment and quantity scaling).

**B) Unofficial Bring! shopping-list API (push ingredients directly).** Reverse-engineered but widely used (it backs the Home Assistant Bring! integration): login with Bring! account credentials, `loadLists`, then `batch_update_list` with `{itemId, spec, uuid}` items. Reference implementations: [miaucl/bring-api](https://github.com/miaucl/bring-api) (Python, maintained), [foxriver76/node-bring-api](https://github.com/foxriver76/node-bring-api) (the original), [felixschndr/mealie-bring-api](https://github.com/felixschndr/mealie-bring-api) (the self-hosted Mealie→Bring! bridge, closest to our use case — it exists precisely because Mealie instances are usually not publicly reachable).

This works fully server-side/offline-friendly, gives control over ingredient/spec splitting, and would become its own `shopping-list` service in a language not used yet (polyglot rule) plus a GraphQL mutation like `addRecipeToShoppingList(recipeId, portions)`. Downsides: unofficial/unstable API, and it requires storing a user's Bring! credentials, so it depends on the authentication item below.

Suggested order: A first (cheap, official, no secrets — a link button plus the `recipeYield`/ingredient-markup fixes), then evaluate B if the login/private-deployment constraint makes A unusable.

### Comments

Explore a tree database as the backing store for a standalone comments service. Model recipe discussions as comment trees, where each comment belongs to a recipe and replies form parent-child relationships. Use the experiment to evaluate how well the tree model supports creating, retrieving, and managing threaded discussions, as well as the database's operational fit.

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
