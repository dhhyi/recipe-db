# Backend search

Typesense provides search; GraphQL remains the source of precise recipe data. Indexed fields and facets are defined in [schema.json](src/schema.json).

## Startup

Development setup creates an ignored, private key in `.secrets/typesense-api-key` and preserves it across runs:

```sh
mise run sync
mise run generate-docker-compose
docker compose up -d --build --wait
```

`mise run setup` and `mise run dev-up` also create the development key. `TYPESENSE_API_KEY_FILE` overrides its location; production requires this variable to point to an externally managed key. Keep the key backed up; restart search and Typesense after rotation. Typesense requires a key, but search callers do not supply it. The API uses the internal REST entrypoint (`http://localhost:3000` below); restrict its network access. Run only one search instance.

## GraphQL operations

Named queries live in [operations.graphql](src/operations.graphql). Each recipe reload uses one query for core data, ratings, image presence, and inspirations, without service-health queries. GraphQL errors under a known optional field preserve that source's previous indexed values while successful sources update; core, unrecognized, and unscoped errors fail the reload. Null ratings or inspirations also preserve previous values, while an error-free null image confirms absence. Only an error-free null recipe authorizes deletion. [generate_operations.py](generate_operations.py) uses the pinned Python `graphql-core` dependency to validate every operation against the synchronized schema and generate independent Zig constants, including any required fragments. It does not generate response types or validate runtime variable values.

`IndexRecipe` also reads required `createdAt`, `updatedAt`, and `nameSortKey`. Dates are strictly parsed from RFC 3339 and stored as `created_at`/`updated_at` int64 Unix microseconds, never indexing time or a default. Malformed/missing dates fail the reload with the recipe ID and source field in diagnostics. Fractional precision beyond microseconds is truncated. Leap seconds are rejected because Unix time cannot represent them distinctly. Rebuilds and optional-source events reuse source dates unchanged. `name_sort` copies the recipes service's German base-letter key; `recipe_id_sort` copies the stable ID. Both strings enable Typesense sorting explicitly. Confirmed unrated values index as zero average/count; source outages still preserve previous ratings or fail for new documents.

After changing operations or the GraphQL schema, synchronize and regenerate:

```sh
mise run sync
mise run --raw in-devcontainer search generate
mise run --raw in-devcontainer search check
```

The devcontainer installs Python and `graphql-core` and generates constants on initialization. Both `zig build` and `zig build test` reject invalid operations or stale constants; the project generation pipeline and Docker build regenerate them. Python validation tests run as part of the project checks and Docker build. Neither Python nor `graphql-core` is included in the production runtime image.

## API and recovery

`POST /search` accepts a flat object of Typesense options. Defaults are `query_by=name,method,ingredients` and `num_typos=2`. Only recipe IDs are returned; field selection and highlighting options cannot override this.

```sh
curl --fail-with-body http://localhost:3000/search \
  -H 'Content-Type: application/json' \
  --data '{"q":"Kartofelsuppe","facet_by":"ingredients","page":1,"per_page":10}'
```

The response contains ordered `recipeIds`, `facetCounts`, `found`, `outOf`, `page` and `perPage`. Grouped hits are flattened in group/hit order. Fetch recipe details through GraphQL. Errors use RFC 9457 Problem Details: invalid options return 400, unavailable dependencies or an incomplete index return 503.

Offset pagination is not a snapshot during writes. Browse deduplicates IDs client-side, but concurrent index updates can still cause skipped hits across pages; snapshot consistency is not guaranteed.

A rebuild runs on startup and every 24 hours after success; failures retry after 30 seconds.

The collection is **`recipes`**, defined directly by `schema.json`; there is no deployed collection to migrate or retain for rollback. Startup creates it if absent and rebuilds its documents before search becomes ready. Editing `schema.json` does not alter an already-created local collection: after schema changes, remove that disposable development collection before restarting search.

To trigger and inspect a rebuild:

```sh
curl --fail-with-body -X POST http://localhost:3000/search/reindex
curl --fail-with-body http://localhost:3000/search/reindex/2 # Use the returned jobId.
curl --fail-with-body http://localhost:3000/search/reindex
```

Job lookup returns 202 while pending/running, 200 on success and 500 on failure. The latest sixteen results are retained; expired jobs return 410. IDs reset on restart. Search is unavailable during rebuilding and after a failed rebuild until recovery. `GET /health` reports liveness, not readiness; inspect `ready` in its body.

Events queue during rebuilds. Active rebuild requests queue another pass; pending requests coalesce. Daily reconciliation recovers missed events and direct backend writes.

Source outages never authorize deletion. Optional fields retain their previous indexed values; without a previous document, an optional-source outage blocks indexing. Restore the dependency and retry/rebuild. Malformed events remain unfinished and require recovery under the [message-bus contract](../message-bus/CONTRACT.md). Inspect status and service logs. For a corrupt/unreadable checkpoint, repair permissions or remove the checkpoint from the search data volume and restart for a full baseline; never advance it manually.

## Sort contract

Typesense 29.0 accepts at most three sort fields. Browse uses these fixed expressions (no browser-supplied Typesense options):

| Sort | `sort_by` |
| --- | --- |
| Relevance with text | `_text_match:desc,created_at:desc,recipe_id_sort:asc` |
| Newest / relevance without text | `created_at:desc,recipe_id_sort:asc` |
| Highest rated | `rating_average:desc,rating_count:desc,recipe_id_sort:asc` |
| Most rated | `rating_count:desc,rating_average:desc,recipe_id_sort:asc` |
| Name A–Z | `name_sort:asc,recipe_id_sort:asc` |
| Name Z–A | `name_sort:desc,recipe_id_sort:asc` |
| Recently updated | `updated_at:desc,recipe_id_sort:asc` |

Zero-valued unrated recipes follow positive ratings without missing-value directives. Explicit sorts prioritize the chosen field over relevance. ID breaks equal keys deterministically.

`test_typesense.py` verifies every expression, equal keys, German keys, unrated values, and microsecond storage against the pinned engine using a uniquely named disposable collection. Run it inside the search devcontainer with `TYPESENSE_TEST_KEY_FILE` pointing to a private mounted key file; no key contents are logged. Normal checks skip these opt-in engine tests when that variable is absent. `search-test` covers source metadata, event reloads, and rebuild preservation on the full deployed stack.
