# MCP Server

Exposes an [MCP](https://modelcontextprotocol.io/) server over Streamable HTTP so agents can add recipes and images, implemented in C#/.NET using the official [ModelContextProtocol](https://github.com/modelcontextprotocol/csharp-sdk) SDK. Calls the `graphql` gateway through a [StrawberryShake](https://chillicream.com/docs/strawberryshake)-generated client, whose build-time code generation fails the build if an operation no longer matches the schema.

Tools:

- `get_recipe_schema` returns the current JSON Schema for `add_recipe`/`change_recipe`'s recipe JSON, so an agent can discover the shape of a recipe (and which optional fields are currently available) without guessing. The recipe JSON itself is a free-form string rather than typed MCP tool parameters because its shape depends on which backend services are online, which a static `inputSchema` can't express.
- `add_recipe` validates recipe JSON and creates a recipe. `inspirations` is only accepted while its service is online.
- `list_recipes` lists all recipes with their id and name.
- `get_recipe` returns the full recipe by ID, including the ordered `images` array with stable IDs. The first image is the default.
- `change_recipe` patches only the recipe fields present in the JSON. Use `add_recipe_image` to import one image and prepend it without replacing earlier images. Use `delete_recipe_image` with the stable ID from `get_recipe` to delete one image; it returns `false` if already absent. Deleting the first image promotes the next.
- `add_rating` rates an existing recipe.

There is intentionally no tool for deleting recipes.

## Image URL imports

The MCP tool descriptions carry the client instructions. Discover `add_recipe_image` and supply a direct image URL reachable by the server without browser authentication. Already-public image URLs work. For local/private photos, the client needs file/browser access and HTTP upload, or the user must provide a hosted URL. Obtain permission and confirm rights to share before external hosting; unlisted URLs are not private, and browser cookies/MCP credentials must not be forwarded.

Any suitable host works. For example, upload to [Tmpfiles](https://tmpfiles.org/api) without an account or API key:

```sh
curl -F "file=@photo.jpg" -F "expire=3600" https://tmpfiles.org/api/v1/upload
```

Read the returned sharing page and extract its actual download link, including any token; do not guess a `/dl/` transformation. Check current [terms](https://tmpfiles.org/tos). Before expiry, call `add_recipe_image` with the `recipeId` and the direct `imageUrl`. Verify the new default in `get_recipe` and load its image URL. Successful imports are stored locally and survive source expiry. Report failures and check state before retrying uncertain outcomes.
