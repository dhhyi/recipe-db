# Recipe DB

This project is intended to be a playground for a microservice architecture in the domain of a recipe collection.

As part of the exercise, I want to try as many different programming languages, frameworks and methods as possible. The goal is to learn how to deal with problems that arise in this polyglot architecture.

There are really just three rules:

- No technology should be used twice. (Different languages, frameworks, libraries, etc.)
- Cut as early as possible to get as many running parts as possible.
- Limit the amount of JavaScript/TypeScript to a minimum. (I see enough of it in my day job.)

# Getting Started

Required for running anything:

- [mise](https://mise.jdx.dev/) (to install development tools)
- docker or comparable container builder
- docker compose

Run `mise install` once, then run `mise run generate-docker-compose` and `docker compose up`. The ytt templates render the development `docker-compose.yml`; production generation also renders the static `traefik.yml` configuration with `mise run generate-docker-compose prod`. The project will be available on http://localhost:8080. Traefik is listening on http://localhost:3000/dashboard/. Apollo GraphQL is available on http://localhost:8080/graphql.

To supply your own recipes, you can use the [demo-data project](demo-data/README.md) to generate demo recipes, ratings, inspirations and images via the GraphQL API.

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

Consistent styling including shared Web Components, see [`design`](./design)

### Agent Integration

Adding recipes and images from an AI agent via an [MCP](https://modelcontextprotocol.io/) server, see [`mcp`](./mcp) ([`mcp-test`](./mcp-test))

## Backend

The backend is organized in a variety of services where the only one _actually_ necessary is the one holding recipe data. Each service exposes a REST API which is tested with a different integration testing framework.

A GraphQL gateway is used to combine all backend REST services into a single API. (see [`graphql`](./graphql) and [`graphql-test`](./graphql-test))

### Recipes — see [`recipes`](./recipes) ([`recipes-test`](./recipes-test))

### Ratings — see [`ratings`](./ratings) ([`ratings-test`](./ratings-test))

### Images — see [`images`](./images) ([`images-test`](./images-test))

### Inspiration — see [`inspirations`](./inspirations) ([`inspirations-test`](./inspirations-test))

### Utility Services

Services with utility character.

#### Link Extract — see [`link-extract`](./link-extract)

#### Image Inline — see [`image-inline`](./image-inline) ([`image-inline-test`](./image-inline-test))

## Dev Support

- VSCode devcontainers for easy setup
- custom precommit
- prettier as formatter for general
- testing with integration test projects
- [demo-data project](demo-data/README.md)
