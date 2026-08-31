# Recipe DB

This project is intended to be a playground for a microservice architecture in the domain of a recipe collection.

As part of the exercise, I want to try as many different programming languages, frameworks and methods as possible.

This README is still a work in progress...

# Getting Started

Required for running anything:

- Node.js >= 18
- docker or comparable container builder
- docker compose

Run `npm run generate-docker-compose` and `docker compose up`. The project will be available on http://localhost:8080. Traefik is listening on http://localhost:3000/dashboard/. Apollo GraphQL is available on http://localhost:8080/graphql.

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

### Parts with limited interaction — see [`frontend`](./frontend)

### Heavy interaction

Parts with heavy interaction like the pages for adding and editing recipes will be implemented in a different solution.

#### Recipe Adding and Editing — see [`recipes-edit`](./recipes-edit)

#### Image Adding and Editing — see [`images-edit`](./images-edit)

### Style

If possible, consistent styling with [Tailwind CSS](https://tailwindcss.com/).

## Backend

The backend is organized in a variety of services where the only one _actually_ necessary is the one holding recipe data. Each service exposes a REST API which is tested with a different integration testing framework.

### Recipes — see [`recipes`](./recipes) ([`recipes-test`](./recipes-test))

### Ratings — see [`ratings`](./ratings) ([`ratings-test`](./ratings-test))

### Images — see [`images`](./images) ([`images-test`](./images-test))

### Inspiration — see [`inspirations`](./inspirations) ([`inspirations-test`](./inspirations-test))

### Utility Services

Services with utility character.

#### Link Extract — see [`link-extract`](./link-extract)

#### Image Inline — see [`image-inline`](./image-inline)

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
