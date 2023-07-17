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

### Parts with limited interaction

For pages that are mostly static, [Astro](https://astro.build/) is a perfect implementation solution for speedy serving and caching.

Astro offers [plugins](https://docs.astro.build/en/guides/integrations-guide/#official-integrations) for different languages for components, which I want to try all.

As most parts of any Astro page can be pre-rendered and cached and rerendered when the data changes, I plan on adding a cache purging solution from backend to frontend later. (Message Que, Websocket)

### Heavy interaction

Parts with heavy interaction like the pages for adding and editing recipes will be implemented in a different solution.

Possibilities:

- [Vaadin](https://vaadin.com/)
  - via [Kotlin](https://vaadin.com/docs/v14/flow/guide/start/kotlin) or [Scala](https://vaadin.com/docs/v8/framework/getting-started/getting-started-scala);
  - testing available via [Karibu](https://github.com/mvysny/karibu-testing/).
- [Hilla](https://hilla.dev/)
  - compatible with [Tailwind CSS](https://hilla.dev/blog/hilla-tailwind-tutorial/)

### Style

If possible, consistent styling with [Tailwind CSS](https://tailwindcss.com/).

## Backend

The backend is organized in a variety of services where the only one _actually_ necessary is the one holding recipe data. Each service exposes a REST API which is tested with a different integration testing framework.

### Recipes

Implemented using [Golang](https://go.dev/), web framework [Gin](https://gin-gonic.com/) and [Clover](https://github.com/ostafen/clover) as document database.

Integration testing done in [Venom](https://github.com/ovh/venom).

### Ratings

Implemented in [IO](https://iolanguage.org/) with [SQLite](https://www.sqlite.org/) as relational database.

Integration testing in [Karate](https://www.karatelabs.io/).

### Tags

TBA, maybe graph database?

Specific tags for:

- Country
- Vegetarian/Vegan/Pescetarian
- Main/Side/Appetizer/Dessert

### Images

Probably self-implemented image server in [Julia](https://julialang.org/)?

### Comments

graph-like data structure

### Food diary

User can track when he had a certain recipe.

### Relations

- Variant of
- Side dish

## Cross Concerns

### searching

- by name
- by rating for user
- recipes containing ingredient/tag

### Caching and updating

Message queue notify on update -> prerender and cache page again.

### Resilience

Maybe later.

## Dev Support

- VSCode devcontainers for easy setup
- custom precommit
- prettier as formatter for general
- testing with integration test projects
- demo-data project
