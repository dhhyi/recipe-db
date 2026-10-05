# Roadmap

## Image handling

### Better image editor

The images frontend should be the only place where the full-size image is loaded, along with a crop overlay that lets the user select the crop area.

## Raspberry Pi deployment

### Check for ARM64 build

Check that all production images can be built for ARM.

### Protect web frontend with login mechanism

The web frontend should be protected with a login mechanism, so that it is not publicly accessible. This should either be simple HTTP basic auth or a more complex solution with OAuth via Google.

### Setup Raspberry Pi deployment

Deploy the production stack on k3s, matching the Raspberry Pi target, rather than supporting production Docker Compose. Use k3d as a local stand-in for testing the production k3s setup. Both of these deployments need templating with ytt.

Set up a public deployment.

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

Prerequisite work is small: `browse` already emits schema.org microdata — `detail.templ` wraps the page in `itemscope itemtype="https://schema.org/Recipe"` with `itemprop="name"`, `image`, `recipeIngredient` and `recipeInstructions`, `overview.templ` marks up the tiles, and `rating.templ` adds an `AggregateRating`. Gaps to close for Bring!: there is no `recipeYield`, so the portion scaler would have to fall back to `baseQuantity` on the link; and `recipeIngredient` sits on the `<tr>` whose amount/unit/name are split across two `<td>`s, so the parsed text needs checking (Bring! splits an ingredient string into `itemId` + `spec` itself). Run the page through [getbring.com/en/integration-check](https://www.getbring.com/en/integration-check) to see what the parser actually extracts before changing anything.

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

Build a dedicated search platform using [Typesense](https://typesense.org/) and a thin Zig service. Target a Raspberry Pi 3 with about 100 recipes initially; verify ARM64 compatibility, memory use, and startup time on the target device.

Index current recipe data exposed by GraphQL, with room to add fields such as tags as they become available. Search German text with full-text search, typo tolerance, facets, and pagination; highlighting is not needed. The service should forward composable Typesense query options and return ordered recipe IDs plus facet and pagination metadata. GraphQL remains the source of precise recipe data. Defer user-specific rating search.

Use NATS JetStream for queued, durable recipe-change notifications. Only mutations performed through GraphQL publish events. The Zig service consumes them with a durable consumer, reloads the recipe through GraphQL, then replaces its Typesense document; confirmed recipe deletions remove the document. Repeated delivery must be safe. If an optional source service is unavailable while rebuilding a document, retain its fields from the previous indexed document rather than erasing them.

Provide a daily scheduled reindex and a way to trigger one manually. Rebuilds may make search unavailable while running. Start with the backend only; frontend integration is separate work.

TODO: address the gap where a recipe mutation succeeds but publishing its notification fails. For the initial happy path, the scheduled reindex provides eventual recovery.

### Caching and updating

Add a temporary disk-backed HTML cache inside `browse`, reusing its existing Go/templ rendering. Assume the search entry's NATS JetStream message bus is available. Start with one `browse` replica and recipe detail pages only; keep Traefik routing, authentication, and compression unchanged. Do not introduce a separate cache service.

Implementation plan:

1. **Cache on demand.** Clear only the dedicated cache directory on every `browse` process start, before accepting requests. Serve valid cached HTML without querying GraphQL. On a miss, fetch the recipe, render the page, atomically save the completed HTML, and serve it. Coalesce concurrent misses for the same recipe. Do not cache failed or incomplete renders; return an explicit error if fresh rendering fails.
2. **Invalidate on updates.** Give `browse` its own durable JetStream consumer, independent of search. Recipe, aggregate-rating, image, deletion, and other changes affecting cached content must identify the affected recipe and invalidate its detail page. Acknowledge events only after successful invalidation; retry failures and make repeated delivery safe. Use per-recipe generations or equivalent coordination so an invalidation during rendering prevents an older result from repopulating the cache. Invalidate locally after successful mutations handled by `browse`, such as rating submissions, rather than waiting for bus delivery.
3. **Separate cached and live content.** Cache the document layout, recipe content, image URLs, and aggregate ratings. Keep service-availability-dependent edit controls live via HTMX, and retain lazy-loaded inspirations without gating their placeholder on cached service health. Mutation responses, widget endpoints, GraphQL, and health checks remain uncached. Shared HTML must contain no user-specific content, and authentication must precede access to cached pages.
4. **Bound staleness.** Use a short fixed TTL measured from the successful fetch, not extended by cache hits, to recover from missed notifications and the mutation-to-publication gap. During bus outages, keep serving valid entries until expiry; expired or invalidated entries require fresh rendering, with no stale fallback on failure. Choose the TTL during implementation. Target invalidation within five seconds under healthy conditions. Ensure browser caching does not hide server-side invalidation, for example with `Cache-Control: no-cache` and a content-derived ETag.
5. **Validate the behavior.** Verify cache hits avoid GraphQL calls, concurrent misses share a render, updates invalidate all variants of the affected page, and in-flight renders cannot restore invalidated content. Test duplicate events, confirmed deletions, rendering and invalidation failures, process restarts, and bus outages with TTL expiry. Ensure temporary optional-service failures cannot silently replace a complete page with incomplete HTML. Add a storage limit and observable cache hits, misses, invalidations, and failures.

Disk storage is disposable and used only during the current process lifetime, not for recovery across restarts. No eager prerendering, full rebuild jobs, extra in-memory cache, multiple replicas, or automatic updates to already-open browser pages initially. Image bytes and browser image-cache invalidation are separate from HTML caching.

### Resilience

Maybe later.

## Misc
