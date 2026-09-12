# MCP Server

Exposes an [MCP](https://modelcontextprotocol.io/) server over Streamable HTTP so agents can add recipes
and images, implemented in C#/.NET using the official
[ModelContextProtocol](https://github.com/modelcontextprotocol/csharp-sdk) SDK. Calls the `graphql`
gateway through a [StrawberryShake](https://chillicream.com/docs/strawberryshake)-generated client, whose
build-time code generation fails the build if an operation no longer matches the schema.

Tools:

- `get_recipe_schema` returns the current JSON Schema for `add_recipe`/`change_recipe`'s recipe JSON, so an
  agent can discover the shape of a recipe (and which optional fields are currently available) without
  guessing. The recipe JSON itself is a free-form string rather than typed MCP tool parameters because its
  shape depends on which backend services are online, which a static `inputSchema` can't express.
- `add_recipe` validates the recipe JSON against a schema generated depending on which backend services
  are currently online (`inspirations`/`imageUrl` are only accepted while the inspirations/images service,
  respectively, is up); an included `imageUrl` is fetched and attached to the new recipe.
- `list_recipes` lists all recipes with their id and name.
- `get_recipe` returns the full details of a single recipe (name, method, ingredients, rating, image,
  inspirations) by id.
- `change_recipe` patches an existing recipe; only fields present in the JSON are changed, the rest are
  left untouched. An included `imageUrl` (only accepted while the images service is online) replaces the
  recipe's image, fetched by the server.
- `add_rating` rates an existing recipe.

There is intentionally no tool for deleting recipes.
