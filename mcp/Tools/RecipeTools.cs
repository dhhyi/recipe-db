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
    OTHER,
}

[McpServerToolType]
public class RecipeTools(
    IMcpClient client,
    IHttpClientFactory httpClientFactory,
    IHttpContextAccessor httpContextAccessor
)
{
    private const string ImageUrlGuidance =
        " 'imageUrl' must be a direct HTTP(S) image URL on a public host, reachable by this server " +
        "without browser authentication, not a local path or sharing page. For local/private photos, " +
        "use client file/browser access and HTTP upload, or ask the user for a hosted URL if unavailable. " +
        "Do not invent missing capabilities or claim success from hosting alone. " +
        "Get user permission and confirm rights to share before external hosting; unlisted URLs are not private. " +
        "Send only the selected image, never browser cookies, MCP credentials or unrelated content. Any suitable host works. " +
        "Optional anonymous Tmpfiles (no account/API key): POST https://tmpfiles.org/api/v1/upload with " +
        "multipart 'file' and 'expire=3600'; read the returned sharing page and extract its actual download " +
        "link, including any token. Never guess a '/dl/' transformation. See https://tmpfiles.org/api and " +
        "https://tmpfiles.org/tos for current limits/terms. Import before expiry; successful imports are " +
        "stored locally and survive source expiry. Verify the added image in 'get_recipe' and load its URL; report " +
        "hosting/fetch/permission/assignment failures and check state before retrying uncertain outcomes.";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.SnakeCaseUpper) },
    };

    [McpServerTool(Name = "get_recipe_schema")]
    [Description(
        "Returns the current JSON Schema for the recipe JSON accepted by 'add_recipe' and 'change_recipe' " +
        "- call this first to discover the shape of recipe data. The optional 'inspirations' field " +
        "only appears while its service is online."
    )]
    public async Task<string> GetRecipeSchema()
    {
        var online = await GetOnlineServicesAsync();
        var create = RecipeSchema.BuildForCreate(online.Contains("inspirations"));
        var update = RecipeSchema.BuildForUpdate(online.Contains("inspirations"));
        return JsonSerializer.Serialize(new { addRecipe = create, changeRecipe = update }, JsonOptions);
    }

    [McpServerTool(Name = "add_recipe")]
    [Description(
        "Creates a recipe from JSON (name required; method, ingredients optional). The " +
        "'inspirations' field (array of URLs) is only accepted while its service is online. " +
        "Use 'add_recipe_image' separately after creating the recipe."
    )]
    public async Task<string> AddRecipe(
        [Description("Recipe JSON object matching 'get_recipe_schema'.")] string recipeJson
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
            throw new McpException($"Invalid JSON: {e.Message}");
        }

        var online = await GetOnlineServicesAsync();
        var schema = RecipeSchema.BuildForCreate(online.Contains("inspirations"));
        var validation = schema.Evaluate(element, new EvaluationOptions { OutputFormat = OutputFormat.List });
        if (!validation.IsValid)
        {
            ValidateIngredientAmounts(element);
            var errors = (validation.Details ?? [])
                .Where(d => d.Errors is { Count: > 0 })
                .SelectMany(d => d.Errors!.Select(e => $"{d.InstanceLocation}: {e.Value}"));
            throw new McpException($"Recipe failed schema validation: {string.Join("; ", errors)}");
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

        return JsonSerializer.Serialize(new { created.Id, created.Name }, JsonOptions);
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
        "Returns the full details of a single recipe (name, method, ingredients, rating, ordered images, " +
        "inspirations, tags) by id. Images include stable IDs, and the first image is the default. " +
        "Use this to inspect the current state of a recipe, e.g. before merging " +
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
            "images" => extensions.GetValueOrDefault("service")?.ToString() == "images",
            "inspirations" => extensions.GetValueOrDefault("service")?.ToString() == "inspirations",
            "tags" => extensions.GetValueOrDefault("service")?.ToString() == "tags",
            _ => false,
        };
    }

    [McpServerTool(Name = "change_recipe")]
    [Description(
        "Patches an existing recipe from JSON; only fields present in the JSON are changed, omitted " +
        "fields are left untouched. The 'inspirations' field (array of URLs) is only accepted while " +
        "its service is online. Use 'add_recipe_image' and 'delete_recipe_image' to manage images."
    )]
    public async Task<string> ChangeRecipe(
        [Description("Recipe id")] string recipeId,
        [Description(
            "Partial recipe JSON object matching 'get_recipe_schema'; only included fields change."
        )] string recipeJson
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
            throw new McpException($"Invalid JSON: {e.Message}");
        }

        var online = await GetOnlineServicesAsync();
        var schema = RecipeSchema.BuildForUpdate(online.Contains("inspirations"));
        var validation = schema.Evaluate(element, new EvaluationOptions { OutputFormat = OutputFormat.List });
        if (!validation.IsValid)
        {
            ValidateIngredientAmounts(element);
            var errors = (validation.Details ?? [])
                .Where(d => d.Errors is { Count: > 0 })
                .SelectMany(d => d.Errors!.Select(e => $"{d.InstanceLocation}: {e.Value}"));
            throw new McpException($"Recipe failed schema validation: {string.Join("; ", errors)}");
        }

        var recipe = JsonNode.Parse(recipeJson)!.AsObject();
        if (recipe.Count == 0)
        {
            return "No recipe fields to change";
        }

        var value = BuildRecipeInput(recipe);
        var response = await client.UpdateRecipe.ExecuteAsync(recipeId, value);
        if (response.Errors.Count > 0)
        {
            throw GraphQLError(response.Errors);
        }

        var updated = response.Data?.UpdateRecipe;
        return updated is null
            ? "Failed to change recipe: no recipe returned"
            : JsonSerializer.Serialize(new { updated.Id, updated.Name }, JsonOptions);
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
    [Description("Lists the fresh tag inventory. Optional category is exactly one of CUISINE, DIETARY_STYLE, COURSE, or OTHER; omit it to list every category.")]
    public async Task<string> ListTags(
        [Description("Optional category: CUISINE, DIETARY_STYLE, COURSE, or OTHER")] TagCategoryChoice? category = null
    )
    {
        var response = await client.ListTags.ExecuteAsync(category is null ? null : ToGraphQlCategory(category.Value));
        if (response.Errors.Count > 0) throw GraphQLError(response.Errors);
        return JsonSerializer.Serialize(response.Data?.Tags ?? [], JsonOptions);
    }

    [McpServerTool(Name = "create_tag")]
    [Description(
        "Creates a tag in CUISINE, DIETARY_STYLE, COURSE, or OTHER. The first creation fixes display spelling. " +
        "Any later creation producing the same normalized ID, including identical spelling or punctuation/accent variants, fails with tag-collision (409); it never reuses or selects an existing tag."
    )]
    public async Task<string> CreateTag(
        [Description("Category: CUISINE, DIETARY_STYLE, COURSE, or OTHER")] TagCategoryChoice category,
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
        TagCategoryChoice.OTHER => Mcp.GraphQL.TagCategory.Other,
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
        var amount = ingredient["amount"];
        return new IngredientInput
        {
            Name = (string)ingredient["name"]!,
            Amount = amount is JsonValue value && value.GetValueKind() == JsonValueKind.Number
                ? value.GetValue<JsonElement>().GetRawText()
                : (string?)amount,
            Unit = (string?)ingredient["unit"],
            Optional = (bool?)ingredient["optional"],
        };
    }

    private static void ValidateIngredientAmounts(JsonElement recipe)
    {
        if (recipe.ValueKind != JsonValueKind.Object
            || !recipe.TryGetProperty("ingredients", out var ingredients)
            || ingredients.ValueKind != JsonValueKind.Array)
        {
            return;
        }

        foreach (var ingredient in ingredients.EnumerateArray())
        {
            if (ingredient.ValueKind == JsonValueKind.Object
                && ingredient.TryGetProperty("amount", out var amount)
                && amount.ValueKind is not (JsonValueKind.String or JsonValueKind.Number))
            {
                throw new McpException("Recipe failed schema validation: ingredient amount expects a string or number.");
            }
        }
    }

    [McpServerTool(Name = "add_recipe_image")]
    [Description(
        "Imports one image into an existing recipe and returns its metadata, including the stable ID. " +
        "The new image becomes the first (default) image without replacing earlier images." + ImageUrlGuidance
    )]
    public async Task<string> AddRecipeImage(
        [Description("Recipe id")] string recipeId,
        [Description("Direct HTTP(S) image URL reachable by the server, not a local path or sharing page.")] string imageUrl,
        CancellationToken cancellationToken
    )
    {
        await RequireImageManagementAsync(cancellationToken);
        if (!Uri.TryCreate(imageUrl, UriKind.Absolute, out var source)
            || source.Scheme is not ("http" or "https")
            || source.UserInfo.Length != 0)
        {
            throw new McpException("Invalid imageUrl: provide a direct HTTP(S) image URL without embedded credentials.");
        }

        var (stream, contentType) = await FetchImageAsync(source, cancellationToken);
        using var image = stream;
        var filename = source.AbsolutePath.Split('/').LastOrDefault(segment => segment.Length > 0) ?? "image";
        var file = new Upload(stream, filename, contentType);
        var response = await client.AddImage.ExecuteAsync(recipeId, file, cancellationToken);
        if (response.Errors.Count > 0)
        {
            throw GraphQLError(response.Errors);
        }

        var added = response.Data?.AddImage ?? throw new McpException("Failed to add image: no metadata returned");
        return JsonSerializer.Serialize(new { added.Id, added.Url, added.ThumbUrl, added.Width, added.Height, added.Size }, JsonOptions);
    }

    private async Task<(MemoryStream Stream, string ContentType)> FetchImageAsync(
        Uri source, CancellationToken cancellationToken
    )
    {
        using var http = httpClientFactory.CreateClient(ImageSource.ClientName);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(http.Timeout);
        var token = deadline.Token;
        const string tooLarge = "Failed to fetch image: source exceeds the 10 MiB download limit";
        try
        {
            using var response = await http.GetAsync(source, HttpCompletionOption.ResponseHeadersRead, token);
            if (!response.IsSuccessStatusCode)
                throw new McpException($"Failed to fetch image: HTTP {(int)response.StatusCode}");
            if (response.Content.Headers.ContentLength > ImageSource.MaxBytes)
                throw new McpException(tooLarge);

            using var body = await response.Content.ReadAsStreamAsync(token);
            var image = new MemoryStream();
            try
            {
                var buffer = new byte[81920];
                int read;
                while ((read = await body.ReadAsync(buffer, token)) > 0)
                {
                    if (image.Length + read > ImageSource.MaxBytes)
                        throw new McpException(tooLarge);
                    image.Write(buffer, 0, read);
                }
                image.Position = 0;
                return (image, response.Content.Headers.ContentType?.MediaType ?? "application/octet-stream");
            }
            catch
            {
                image.Dispose();
                throw;
            }
        }
        catch (Exception e) when (e is HttpRequestException or IOException)
        {
            throw new McpException("Failed to fetch image: could not download the source URL");
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new McpException("Failed to fetch image: source request timed out");
        }
    }

    private async Task RequireImageManagementAsync(CancellationToken cancellationToken)
    {
        var response = await client.ImageManagementCapability.ExecuteAsync(cancellationToken);
        if (response.Errors.Count > 0)
        {
            throw GraphQLError(response.Errors);
        }

        var capabilities = response.Data?.MyCapabilities
            ?? throw new McpException("Failed to verify permission to manage images");
        if (!capabilities.CanManageImages)
        {
            // GraphQL distinguishes credential-free guests from authenticated principals with the same role.
            var credentialFree = httpContextAccessor.HttpContext?.Request.Headers.ContainsKey("Authorization") != true;
            throw new McpException(capabilities.Role == "anonymous" && credentialFree
                ? "authentication-required: Sign in to manage images (status: 401)"
                : "forbidden: You do not have permission to manage images (status: 403)");
        }
    }

    [McpServerTool(Name = "delete_recipe_image")]
    [Description(
        "Deletes only the image with the given stable ID (from 'get_recipe'). Returns true if deleted, " +
        "false if already absent. Deleting the first image makes the next image the default."
    )]
    public async Task<string> DeleteRecipeImage(
        [Description("Recipe id")] string recipeId,
        [Description("Stable image id from the recipe's images array, not its URL or position.")] string imageId
    )
    {
        var response = await client.DeleteImage.ExecuteAsync(recipeId, imageId);
        if (response.Errors.Count > 0)
        {
            throw GraphQLError(response.Errors);
        }

        var deleted = response.Data?.DeleteImage ?? throw new McpException("Failed to delete image: no result returned");
        return JsonSerializer.Serialize(deleted, JsonOptions);
    }

    [McpServerTool(Name = "reorder_recipe_images")]
    [Description(
        "Sets the recipe's complete image order using stable IDs from 'get_recipe'. " +
        "Include every current image ID exactly once; if membership changed since the order was read, " +
        "the mutation fails. Do not retry automatically; check 'get_recipe' before trying again. " +
        "The first image is the default."
    )]
    public async Task<string> ReorderRecipeImages(
        [Description("Recipe id")] string recipeId,
        [Description("Complete desired image order: every stable image ID from the recipe's images array, exactly once.")] string[] imageIds,
        CancellationToken cancellationToken
    )
    {
        await RequireImageManagementAsync(cancellationToken);
        var response = await client.ReorderImages.ExecuteAsync(recipeId, imageIds, cancellationToken);
        if (response.Errors.Count > 0)
        {
            throw GraphQLError(response.Errors);
        }

        var images = response.Data?.ReorderImages
            ?? throw new McpException("Failed to reorder images: no ordered metadata returned");
        return JsonSerializer.Serialize(
            images.Select(image => new
            {
                image.Id,
                image.Url,
                image.ThumbUrl,
                image.Width,
                image.Height,
                image.Size,
            }),
            JsonOptions
        );
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
