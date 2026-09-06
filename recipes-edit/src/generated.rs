use graphql_client::GraphQLQuery;

// Custom scalar from recipe-db.graphqls, used for ingredient amounts (e.g. "1" or 1).
type StringOrInt = serde_json::Value;

#[derive(GraphQLQuery)]
#[graphql(
    schema_path = "recipe-db.graphqls",
    query_path = "operations.graphql",
    response_derives = "Debug, Clone, Serialize"
)]
pub struct RecipeById;

// without skip_serializing_none, a None field would be serialized as null, which clears it on the server
#[derive(GraphQLQuery)]
#[graphql(
    schema_path = "recipe-db.graphqls",
    query_path = "operations.graphql",
    response_derives = "Debug",
    variables_derives = "Debug, Clone, Deserialize",
    skip_serializing_none
)]
pub struct CreateRecipe;

// without skip_serializing_none, a None field would be serialized as null, which clears it on the server
#[derive(GraphQLQuery)]
#[graphql(
    schema_path = "recipe-db.graphqls",
    query_path = "operations.graphql",
    response_derives = "Debug",
    variables_derives = "Debug, Clone, Deserialize",
    skip_serializing_none
)]
pub struct UpdateRecipe;
