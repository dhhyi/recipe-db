# Recipe DB

This project is intended to be a playground for a microservice architecture in the domain of a recipe collection.

As part of the exercise, I want to try as many different programming languages, frameworks and methods as possible.

This README is still a work in progress...

# Getting Started

Required for running anything:

- Node.js >= 18
- docker or comparable container builder
- docker compose

Run `npm run generate-docker-compose` and `docker compose up`. The project will be available on http://localhost. Traefik is listening on http://localhost:8080. Apollo GraphQL is available on http://localhost/graphql.

Required for development:

- pnpm (`npm i -g pnpm`)
- @devcontainers/cli (`npm i -g @devcontainers/cli@latest`)
- VSCode

After project checkout, run `pnpm install`. This will generate all necessary files for development (config files for prettier and docker as well as VSCode devcontainers).

# Technologies / Building Blocks

The project is organized in a mono repo. All individual projects provide docker images that can be built independently.

## General Architecture

Every aspect in the Recipe DB is bundled in a microservice. [Traefik](https://traefik.io/) is used to glue everything together.
All individual backend services are made available to the frontend via [Apollo GraphQL](https://www.apollographql.com/).
For building all of the projects in the mono repo, [Docker](https://www.docker.com/) is used as a programming language agnostic builder.

## Frontend

Even though the frontend parts have access to a unified GraphQL API, I want to implement the different parts with different solutions.

### Parts with limited interaction ([`frontend`](./frontend))

For pages that are mostly static, [Astro](https://astro.build/) is a perfect implementation solution for speedy serving and caching.

Astro offers [plugins](https://docs.astro.build/en/guides/integrations-guide/#official-integrations) for different languages for components, which I want to try all.

As most parts of any Astro page can be pre-rendered and cached and rerendered when the data changes, I plan on adding a cache purging solution from backend to frontend later. (Message Que, Websocket)

### Heavy interaction

Parts with heavy interaction like the pages for adding and editing recipes will be implemented in a different solution.

#### Recipe Adding and Editing ([`recipes-edit`](./recipes-edit))

Implemented in [Vaadin](https://vaadin.com/) via [Kotlin](https://vaadin.com/docs/v14/flow/guide/start/kotlin). with [Gradle](https://gradle.org/) build tool and [Spring Boot](https://spring.io/projects/spring-boot) for app startup.

### Style

If possible, consistent styling with [Tailwind CSS](https://tailwindcss.com/).

## Backend

The backend is organized in a variety of services where the only one _actually_ necessary is the one holding recipe data. Each service exposes a REST API which is tested with a different integration testing framework.

### Recipes ([`recipes`](./recipes), [`recipes-test`](./recipes-test))

Implemented using [Golang](https://go.dev/), web framework [Gin](https://gin-gonic.com/) and [Clover](https://github.com/ostafen/clover) as document database.

Still open: versioning of recipe data and rollback of edits.

Integration testing done in [Venom](https://github.com/ovh/venom).

### Ratings ([`ratings`](./ratings), [`ratings-test`](./ratings-test))

Implemented in [IO](https://iolanguage.org/) with [SQLite](https://www.sqlite.org/) as relational database.

Integration testing in [Karate](https://www.karatelabs.io/).

### Images

Image server implemented in [Julia](https://julialang.org/) using [Genie](https://genieframework.com/) and [JuliaImages](https://juliaimages.org/latest/).
Testing is part of the precompile/warm-up process.

### Inspiration ([`inspirations`](./inspirations), [`inspirations-test`](./inspirations-test))

Sources of inspiration web links for this recipe.
Implemented in [Lua](https://www.lua.org/) using [Milua](https://github.com/MiguelMJ/Milua) for setting up REST API.
Data stored as plain JSON File.

Testing is done using [Venom](https://github.com/ovh/venom) with [Tavern Executor](https://github.com/intercloud/venom/tree/executor-tavern/executors/tavern)

### Utility Services

Services with utility character.

#### Link Extract ([`link-extract`](./link-extract))

Extracts favicon, title, description and canonical link of URL.

Implemented in [Deno](https://deno.land/) using [Denorest](https://denorest.deno.dev/) and [AloeDB](https://github.com/Kirlovon/AloeDB) document database.

#### Image Inline ([`image-inline`](./image-inline))

Convert an Image URL to an inlined image.
Implemented in [Perl](https://www.perl.org/) using [Dancer2](https://metacpan.org/pod/Dancer2) for the REST API setup.

## Ideas for other services:

### Tags

TBA, maybe graph database?

Specific tags for:

- Country
- Vegetarian/Vegan/Pescetarian
- Main/Side/Appetizer/Dessert

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

## Dev Support

- VSCode devcontainers for easy setup
- custom precommit
- prettier as formatter for general
- testing with integration test projects
- demo-data project

## List of possible REST API testing frameworks

- https://github.com/brooklynDev/airborne
- https://github.com/martinmaher/jcache-chat-citrus
- https://citrusframework.org/citrus/reference/3.4.0/html/index.html#http-rest
- https://gettaurus.org/
- https://github.com/svanoort/pyresttest
- https://rest-assured.io/
- https://www.baeldung.com/cucumber-rest-api-testing
