# Demo Data

Generates demo recipes, ratings, inspirations and images via the GraphQL API. Implemented in Python using a codegen'd GraphQL client ([ariadne-codegen](https://github.com/mirumee/ariadne-codegen)).

This local development utility and its seeding launcher do not have automated tests. Do not add unit tests; troubleshoot failures when using it.

Run it on demand from the repository root against the running local demo cluster:

```sh
mise run seed-demodata
```

This rebuilds the image (so local changes are always picked up), deletes any existing recipes/ratings/inspirations/images, repopulates fresh demo data, and exits. It uses the generated local owner token from `e2e-test/.secrets/auth-tokens.json`; GraphQL must have loaded the matching auth fixture.

If recipe data already exists, the script asks for confirmation before deleting it (`[y/N]` prompt). When run non-interactively (no TTY attached, e.g. in CI) it refuses and exits with an error instead of prompting. Set `FORCE_DELETE=1` to skip the confirmation and delete unconditionally:

```sh
FORCE_DELETE=1 mise run seed-demodata
```
