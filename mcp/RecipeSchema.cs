using Json.Schema;

namespace Mcp;

/// Builds the recipe validation schema; `inspirations`/`imageUrl` are only accepted while their
/// respective backend services are online.
static class RecipeSchema
{
    private static readonly JsonSchemaBuilder Ingredient = new JsonSchemaBuilder()
        .Type(SchemaValueType.Object)
        .Properties(
            ("name", new JsonSchemaBuilder().Type(SchemaValueType.String).MinLength(1)),
            ("amount", new JsonSchemaBuilder().Type(SchemaValueType.String | SchemaValueType.Number)),
            ("unit", new JsonSchemaBuilder().Type(SchemaValueType.String)),
            ("optional", new JsonSchemaBuilder().Type(SchemaValueType.Boolean)))
        .Required("name")
        .AdditionalProperties(false);

    public static JsonSchema BuildForCreate(bool inspirationsOnline, bool imagesOnline) =>
        Build(inspirationsOnline, imagesOnline, requireName: true);

    public static JsonSchema BuildForUpdate(bool inspirationsOnline, bool imagesOnline) =>
        Build(inspirationsOnline, imagesOnline, requireName: false);

    private static JsonSchema Build(bool inspirationsOnline, bool imagesOnline, bool requireName)
    {
        var properties = new Dictionary<string, JsonSchemaBuilder>
        {
            ["name"] = new JsonSchemaBuilder().Type(SchemaValueType.String).MinLength(1),
            ["method"] = new JsonSchemaBuilder().Type(SchemaValueType.String),
            ["ingredients"] = new JsonSchemaBuilder().Type(SchemaValueType.Array).Items(Ingredient),
        };

        if (inspirationsOnline)
        {
            properties["inspirations"] = new JsonSchemaBuilder()
                .Type(SchemaValueType.Array)
                .Items(new JsonSchemaBuilder().Type(SchemaValueType.String).Format(Formats.Uri));
        }

        if (imagesOnline)
        {
            properties["imageUrl"] = new JsonSchemaBuilder().Type(SchemaValueType.String).Format(Formats.Uri);
        }

        var builder = new JsonSchemaBuilder()
            .Type(SchemaValueType.Object)
            .Properties(properties)
            .AdditionalProperties(false);

        return (requireName ? builder.Required("name") : builder).Build();
    }
}
