using System.ComponentModel;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Nodes;
using Json.Schema;
using Mcp.GraphQL;
using ModelContextProtocol.Server;
using StrawberryShake;

namespace Mcp.Tools;

[McpServerToolType]
public class RecipeTools(IMcpClient client, IHttpClientFactory httpClientFactory)
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
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
            return $"Failed to create recipe: {string.Join("; ", response.Errors.Select(e => e.Message))}";
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
            return $"Failed to list recipes: {string.Join("; ", response.Errors.Select(e => e.Message))}";
        }

        var recipes = response.Data?.Recipes ?? [];
        return JsonSerializer.Serialize(recipes.Select(r => new { r.Id, r.Name }), JsonOptions);
    }

    [McpServerTool(Name = "get_recipe")]
    [Description(
        "Returns the full details of a single recipe (name, method, ingredients, rating, image, " +
        "inspirations) by id - use this to inspect the current state of a recipe, e.g. before merging " +
        "new data into it with 'change_recipe'."
    )]
    public async Task<string> GetRecipe([Description("Recipe id")] string recipeId)
    {
        var response = await client.GetRecipe.ExecuteAsync(recipeId);
        if (response.Errors.Count > 0)
        {
            return $"Failed to get recipe: {string.Join("; ", response.Errors.Select(e => e.Message))}";
        }

        var recipe = response.Data?.Recipe;
        return recipe is null ? "Recipe not found" : JsonSerializer.Serialize(recipe, JsonOptions);
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
                return $"Failed to change recipe: {string.Join("; ", response.Errors.Select(e => e.Message))}";
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
        return (response.Data?.OnlineServices ?? []).ToHashSet();
    }

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
            return $"Failed to upload image: {string.Join("; ", response.Errors.Select(e => e.Message))}";
        }

        return response.Data?.SetImage == true ? "Image uploaded" : "Failed to upload image";
    }

    [McpServerTool(Name = "add_rating")]
    [Description("Adds a rating for an existing recipe.")]
    public async Task<string> AddRating(
        [Description("Recipe id")] string recipeId,
        [Description("Rating value")] int rating,
        [Description("Login/username of the rater")] string login
    )
    {
        var response = await client.Rate.ExecuteAsync(recipeId, rating, login);
        if (response.Errors.Count > 0)
        {
            return $"Failed to add rating: {string.Join("; ", response.Errors.Select(e => e.Message))}";
        }

        var result = response.Data?.Rate;
        return result is null
            ? "Failed to add rating: no result returned"
            : JsonSerializer.Serialize(new { result.Average, result.Count }, JsonOptions);
    }
}
