using System.ComponentModel;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Nodes;
using Json.Schema;
using Mcp.GraphQL;
using ModelContextProtocol;
using ModelContextProtocol.Server;
using StrawberryShake;

namespace Mcp.Tools;

public enum TagCategoryChoice
{
    CUISINE,
    DIETARY_STYLE,
    COURSE,
}

[McpServerToolType]
public class RecipeTools(IMcpClient client, IHttpClientFactory httpClientFactory)
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseUpper) },
    };

    [McpServerTool(Name = "get_recipe_schema")]
    [Description(
        "Returns the current JSON Schema for the recipe JSON accepted by 'add_recipe' and 'change_recipe' " +
        "- call this first to discover the shape of recipe data, since optional fields (e.g. " +
        "'inspirations', 'imageUrl') only appear while their backend service is online."
    )]
    public async Task<string> GetRecipeSchema()
    {
        var online = await GetOnlineServicesAsync();
        var create = RecipeSchema.BuildForCreate(online.Contains("inspirations"), online.Contains("images"));
        var update = RecipeSchema.BuildForUpdate(online.Contains("inspirations"), online.Contains("images"));
        return JsonSerializer.Serialize(new { addRecipe = create, changeRecipe = update }, JsonOptions);
    }

    [McpServerTool(Name = "add_recipe")]
    [Description(
        "Creates a recipe from JSON (name required; method, ingredients optional). The " +
        "'inspirations' field (array of URLs) and 'imageUrl' field are only accepted while the " +
        "inspirations/images services (respectively) are online; if 'imageUrl' is given, the server " +
        "fetches it and attaches it to the new recipe."
    )]
    public async Task<string> AddRecipe(
        [Description("Recipe JSON object")] string recipeJson
    )
    {
        JsonElement element;
        try
        {
            using var document = JsonDocument.Parse(recipeJson);
            element = document.RootElement.Clone();
        }
        catch (JsonException e)
        {
            return $"Invalid JSON: {e.Message}";
        }

        var online = await GetOnlineServicesAsync();
        var schema = RecipeSchema.BuildForCreate(online.Contains("inspirations"), online.Contains("images"));
        var validation = schema.Evaluate(element, new EvaluationOptions { OutputFormat = OutputFormat.List });
        if (!validation.IsValid)
        {
            var errors = (validation.Details ?? [])
                .Where(d => d.Errors is { Count: > 0 })
                .SelectMany(d => d.Errors!.Select(e => $"{d.InstanceLocation}: {e.Value}"));
            return $"Recipe failed schema validation: {string.Join("; ", errors)}";
        }

        var recipe = JsonNode.Parse(recipeJson)!.AsObject();
        var value = BuildRecipeInput(recipe);

        var response = await client.CreateRecipe.ExecuteAsync(value);
        if (response.Errors.Count > 0)
        {
            throw GraphQLError(response.Errors);
        }

        var created = response.Data?.CreateRecipe;
        if (created is null)
        {
            return "Failed to create recipe: no recipe returned";
        }

        var result = JsonSerializer.Serialize(new { created.Id, created.Name }, JsonOptions);
        if (recipe.TryGetPropertyValue("imageUrl", out var imageUrlNode) && (string?)imageUrlNode is { } imageUrl)
        {
            result = $"{result}; {await FetchAndSetImageAsync(created.Id, imageUrl)}";
        }

        return result;
    }

    [McpServerTool(Name = "list_recipes")]
    [Description("Lists all recipes with their id and name.")]
    public async Task<string> ListRecipes()
    {
        var response = await client.ListRecipes.ExecuteAsync();
        if (response.Errors.Count > 0)
        {
            throw GraphQLError(response.Errors);
        }

        var recipes = response.Data?.Recipes ?? [];
        return JsonSerializer.Serialize(recipes.Select(r => new { r.Id, r.Name }), JsonOptions);
    }

    [McpServerTool(Name = "get_recipe")]
    [Description(
        "Returns the full details of a single recipe (name, method, ingredients, rating, image, " +
        "inspirations, tags) by id - use this to inspect the current state of a recipe, e.g. before merging " +
        "new data into it with 'change_recipe'. Optional enrichment outages return the recipe with an " +
        "errors array describing the unavailable fields."
    )]
    public async Task<string> GetRecipe([Description("Recipe id")] string recipeId)
    {
        var response = await client.GetRecipe.ExecuteAsync(recipeId);
        var optionalErrors = response.Errors.Count > 0 && response.Errors.All(IsOptionalRecipeError);
        if (response.Errors.Count > 0 && !optionalErrors)
        {
            throw GraphQLError(response.Errors);
        }

        var recipe = response.Data?.Recipe;
        if (recipe is null)
        {
            return "Recipe not found";
        }

        return optionalErrors
            ? JsonSerializer.Serialize(
                new
                {
                    recipe,
                    errors = response.Errors.Select(error => new
                    {
                        error.Message,
                        error.Path,
                        code = error.Extensions?.GetValueOrDefault("code"),
                        status = error.Extensions?.GetValueOrDefault("status"),
                        service = error.Extensions?.GetValueOrDefault("service"),
                    }),
                },
                JsonOptions
            )
            : JsonSerializer.Serialize(recipe, JsonOptions);
    }

    private static bool IsOptionalRecipeError(IClientError error)
    {
        var extensions = error.Extensions;
        if (
            extensions?.GetValueOrDefault("code")?.ToString() != "service-unavailable"
            || extensions.GetValueOrDefault("status")?.ToString() != "503"
            || error.Path is not { Count: >= 2 } path
            || !string.Equals(path[0]?.ToString(), "recipe", StringComparison.Ordinal)
        )
        {
            return false;
        }

        var service = path[1]?.ToString();
        return service switch
        {
            "rating" => extensions.GetValueOrDefault("service")?.ToString() == "ratings",
            "image" => extensions.GetValueOrDefault("service")?.ToString() == "images",
            "inspirations" => extensions.GetValueOrDefault("service")?.ToString() == "inspirations",
            "tags" => extensions.GetValueOrDefault("service")?.ToString() == "tags",
            _ => false,
        };
    }

    [McpServerTool(Name = "change_recipe")]
    [Description(
        "Patches an existing recipe from JSON; only fields present in the JSON are changed, omitted " +
        "fields are left untouched. The 'inspirations' field (array of URLs) and 'imageUrl' field are " +
        "only accepted while the inspirations/images services (respectively) are online; if 'imageUrl' " +
        "is given, the server fetches it and replaces the recipe's image."
    )]
    public async Task<string> ChangeRecipe(
        [Description("Recipe id")] string recipeId,
        [Description("Partial recipe JSON object; only included fields are changed")] string recipeJson
    )
    {
        JsonElement element;
        try
        {
            using var document = JsonDocument.Parse(recipeJson);
            element = document.RootElement.Clone();
        }
        catch (JsonException e)
        {
            return $"Invalid JSON: {e.Message}";
        }

        var online = await GetOnlineServicesAsync();
        var schema = RecipeSchema.BuildForUpdate(online.Contains("inspirations"), online.Contains("images"));
        var validation = schema.Evaluate(element, new EvaluationOptions { OutputFormat = OutputFormat.List });
        if (!validation.IsValid)
        {
            var errors = (validation.Details ?? [])
                .Where(d => d.Errors is { Count: > 0 })
                .SelectMany(d => d.Errors!.Select(e => $"{d.InstanceLocation}: {e.Value}"));
            return $"Recipe failed schema validation: {string.Join("; ", errors)}";
        }

        var recipe = JsonNode.Parse(recipeJson)!.AsObject();
        var hasRecipeFields = recipe.Any(property => property.Key != "imageUrl");

        string result;
        if (hasRecipeFields)
        {
            var value = BuildRecipeInput(recipe);
            var response = await client.UpdateRecipe.ExecuteAsync(recipeId, value);
            if (response.Errors.Count > 0)
            {
                throw GraphQLError(response.Errors);
            }

            var updated = response.Data?.UpdateRecipe;
            if (updated is null)
            {
                return "Failed to change recipe: no recipe returned";
            }

            result = JsonSerializer.Serialize(new { updated.Id, updated.Name }, JsonOptions);
        }
        else
        {
            result = "No recipe fields to change";
        }

        if (recipe.TryGetPropertyValue("imageUrl", out var imageUrlNode) && (string?)imageUrlNode is { } imageUrl)
        {
            result = $"{result}; {await FetchAndSetImageAsync(recipeId, imageUrl)}";
        }

        return result;
    }

    private async Task<HashSet<string>> GetOnlineServicesAsync()
    {
        var response = await client.OnlineServices.ExecuteAsync();
        if (response.Errors.Count > 0)
        {
            throw GraphQLError(response.Errors);
        }
        return (response.Data?.OnlineServices ?? []).ToHashSet();
    }

    private static McpException GraphQLError(IReadOnlyList<IClientError> errors)
    {
        return new McpException(string.Join("; ", errors.Select(error =>
        {
            var code = error.Extensions?.TryGetValue("code", out var codeValue) == true
                ? $"{codeValue}: "
                : "";
            var field = error.Extensions?.TryGetValue("field", out var fieldValue) == true
                ? $" (field: {fieldValue})"
                : "";
            var status = error.Extensions?.TryGetValue("status", out var statusValue) == true
                ? $" (status: {statusValue})"
                : "";
            var partialEffects = error.Extensions is { } extensions
                ? new[] { "recipeId", "completedSteps", "outcome" }
                    .Where(extensions.ContainsKey)
                    .Select(key => $"{key}: {JsonSerializer.Serialize(extensions[key], JsonOptions)}")
                    .ToArray()
                : [];
            var effects = partialEffects.Length == 0
                ? ""
                : $" ({string.Join(", ", partialEffects)})";
            return $"{code}{error.Message}{field}{status}{effects}";
        })));
    }

    [McpServerTool(Name = "list_tags")]
    [Description("Lists the fresh tag inventory. Optional category is exactly one of CUISINE, DIETARY_STYLE, or COURSE; omit it to list every category.")]
    public async Task<string> ListTags(
        [Description("Optional category: CUISINE, DIETARY_STYLE, or COURSE")] TagCategoryChoice? category = null
    )
    {
        var response = await client.ListTags.ExecuteAsync(category is null ? null : ToGraphQlCategory(category.Value));
        if (response.Errors.Count > 0) throw GraphQLError(response.Errors);
        return JsonSerializer.Serialize(response.Data?.Tags ?? [], JsonOptions);
    }

    [McpServerTool(Name = "create_tag")]
    [Description(
        "Creates a tag in CUISINE, DIETARY_STYLE, or COURSE. The first creation fixes display spelling. " +
        "Any later creation producing the same normalized ID, including identical spelling or punctuation/accent variants, fails with tag-collision (409); it never reuses or selects an existing tag."
    )]
    public async Task<string> CreateTag(
        [Description("Category: CUISINE, DIETARY_STYLE, or COURSE")] TagCategoryChoice category,
        [Description("Tag display name")] string name
    )
    {
        var response = await client.CreateTag.ExecuteAsync(ToGraphQlCategory(category), name);
        if (response.Errors.Count > 0) throw GraphQLError(response.Errors);
        return JsonSerializer.Serialize(response.Data?.CreateTag, JsonOptions);
    }

    [McpServerTool(Name = "delete_tag")]
    [Description("Deletes an unused tag by its opaque tag ID. Deleting a tag with recipe assignments returns a structured backend error.")]
    public async Task<string> DeleteTag([Description("Opaque tag ID")] string tagId)
    {
        var response = await client.DeleteTag.ExecuteAsync(tagId);
        if (response.Errors.Count > 0) throw GraphQLError(response.Errors);
        return response.Data?.DeleteTag == true
            ? JsonSerializer.Serialize(new { deleted = true }, JsonOptions)
            : throw new McpException("tag-delete-failed: Tag deletion did not succeed");
    }

    [McpServerTool(Name = "change_recipe_tags")]
    [Description(
        "Atomically adds and/or removes tag IDs from a recipe in one bulk operation. Omit either array or pass an empty array for no change; explicit null is invalid. " +
        "Each optional array must contain unique opaque IDs; unknown IDs, duplicates, overlaps, or any invalid change reject the entire operation."
    )]
    public async Task<string> ChangeRecipeTags(
        [Description("Recipe ID")] string recipeId,
        [Description("Optional opaque tag IDs to add; omit or pass [] for no change, null is invalid")] string[] addTagIds = null!,
        [Description("Optional opaque tag IDs to remove; omit or pass [] for no change, null is invalid")] string[] removeTagIds = null!
    )
    {
        var response = await client.ChangeRecipeTags.ExecuteAsync(
            recipeId,
            addTagIds ?? [],
            removeTagIds ?? []
        );
        if (response.Errors.Count > 0) throw GraphQLError(response.Errors);
        return JsonSerializer.Serialize(response.Data?.ChangeRecipeTags ?? [], JsonOptions);
    }

    private static Mcp.GraphQL.TagCategory ToGraphQlCategory(TagCategoryChoice category) => category switch
    {
        TagCategoryChoice.CUISINE => Mcp.GraphQL.TagCategory.Cuisine,
        TagCategoryChoice.DIETARY_STYLE => Mcp.GraphQL.TagCategory.DietaryStyle,
        TagCategoryChoice.COURSE => Mcp.GraphQL.TagCategory.Course,
        _ => throw new ArgumentOutOfRangeException(nameof(category)),
    };

    private static RecipeInput BuildRecipeInput(JsonObject recipe)
    {
        var value = new RecipeInput();
        if (recipe.ContainsKey("name"))
        {
            value.Name = (string?)recipe["name"];
        }
        if (recipe.ContainsKey("method"))
        {
            value.Method = (string?)recipe["method"];
        }
        if (recipe.ContainsKey("ingredients"))
        {
            value.Ingredients = recipe["ingredients"]?.AsArray().Select(MapIngredient).ToList();
        }
        if (recipe.ContainsKey("inspirations"))
        {
            value.Inspirations = recipe["inspirations"]?.AsArray().Select(url => (string)url!).ToList();
        }
        return value;
    }

    private static IngredientInput MapIngredient(JsonNode? node)
    {
        var ingredient = node!.AsObject();
        return new IngredientInput
        {
            Name = (string)ingredient["name"]!,
            Amount = (string?)ingredient["amount"],
            Unit = (string?)ingredient["unit"],
            Optional = (bool?)ingredient["optional"],
        };
    }

    private async Task<string> FetchAndSetImageAsync(string recipeId, string imageUrl)
    {
        using var http = httpClientFactory.CreateClient();
        HttpResponseMessage imageResponse;
        try
        {
            imageResponse = await http.GetAsync(imageUrl);
        }
        catch (HttpRequestException e)
        {
            return $"Failed to fetch image: {e.Message}";
        }

        if (!imageResponse.IsSuccessStatusCode)
        {
            return $"Failed to fetch image: {(int)imageResponse.StatusCode} {imageResponse.ReasonPhrase}";
        }

        var contentType = imageResponse.Content.Headers.ContentType?.MediaType ?? "application/octet-stream";
        var filename = imageUrl.Split('/', '?').LastOrDefault(segment => segment.Length > 0) ?? "image";

        await using var stream = await imageResponse.Content.ReadAsStreamAsync();
        var file = new Upload(stream, filename, contentType);
        var response = await client.SetImage.ExecuteAsync(recipeId, file);
        if (response.Errors.Count > 0)
        {
            throw GraphQLError(response.Errors);
        }

        return response.Data?.SetImage is not null ? "Image uploaded" : "Failed to upload image";
    }

    [McpServerTool(Name = "add_rating")]
    [Description("Adds a rating for an existing recipe.")]
    public async Task<string> AddRating(
        [Description("Recipe id")] string recipeId,
        [Description("Rating value")] int rating
    )
    {
        var response = await client.Rate.ExecuteAsync(recipeId, rating);
        if (response.Errors.Count > 0)
        {
            throw GraphQLError(response.Errors);
        }

        var result = response.Data?.Rate;
        return result is null
            ? "Failed to add rating: no result returned"
            : JsonSerializer.Serialize(new { result.Average, result.Count }, JsonOptions);
    }
}
