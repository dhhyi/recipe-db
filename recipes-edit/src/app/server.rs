use crate::generated::recipe_by_id::RecipeByIdRecipe;
use leptos::prelude::*;
use leptos::server_fn::{
    codec::JsonEncoding,
    error::{FromServerFnError, ServerFnErrorErr},
};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub enum RecipeError {
    EmptyName,
    Other(String),
}

impl std::fmt::Display for RecipeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RecipeError::EmptyName => f.write_str("Name darf nicht leer sein."),
            RecipeError::Other(message) => f.write_str(message),
        }
    }
}

impl FromServerFnError for RecipeError {
    type Encoder = JsonEncoding;

    fn from_server_fn_error(value: ServerFnErrorErr) -> Self {
        RecipeError::Other(value.to_string())
    }
}

#[cfg(feature = "ssr")]
fn is_empty_name_error(error: &graphql_client::Error) -> bool {
    error.extensions.as_ref().is_some_and(|extensions| {
        extensions.get("code").and_then(serde_json::Value::as_str) == Some("BAD_USER_INPUT")
            && extensions.get("field").and_then(serde_json::Value::as_str) == Some("name")
    })
}

#[cfg(feature = "ssr")]
async fn graphql_request<Q: graphql_client::GraphQLQuery>(
    variables: Q::Variables,
) -> Result<Q::ResponseData, RecipeError> {
    use graphql_client::Response;

    let endpoint =
        std::env::var("GRAPHQL_API").unwrap_or_else(|_| "http://traefik/graphql".to_string());

    let response: Response<Q::ResponseData> = reqwest::Client::new()
        .post(endpoint)
        .json(&Q::build_query(variables))
        .send()
        .await
        .and_then(|response| response.error_for_status())
        .map_err(|error| RecipeError::Other(error.to_string()))?
        .json()
        .await
        .map_err(|error| RecipeError::Other(error.to_string()))?;

    if let Some(errors) = response.errors.filter(|errors| !errors.is_empty()) {
        if errors.iter().any(is_empty_name_error) {
            return Err(RecipeError::EmptyName);
        }
        let messages = errors
            .into_iter()
            .map(|error| error.message)
            .collect::<Vec<_>>()
            .join("; ");
        return Err(RecipeError::Other(messages));
    }

    response
        .data
        .ok_or_else(|| RecipeError::Other("no data returned".to_string()))
}

// the app is mounted under /edit, so server functions have to live below that prefix as well
#[server(prefix = "/edit/api")]
pub async fn fetch_recipe(id: String) -> Result<Option<RecipeByIdRecipe>, RecipeError> {
    use crate::generated::{recipe_by_id, RecipeById};

    let data = graphql_request::<RecipeById>(recipe_by_id::Variables { id }).await?;
    Ok(data.recipe)
}

#[server(prefix = "/edit/api")]
pub async fn save_recipe(
    id: String,
    input: crate::generated::update_recipe::RecipeInput,
) -> Result<(), RecipeError> {
    use crate::generated::{update_recipe, UpdateRecipe};

    graphql_request::<UpdateRecipe>(update_recipe::Variables { id, input }).await?;
    Ok(())
}

#[server(prefix = "/edit/api")]
pub async fn create_recipe(
    input: crate::generated::create_recipe::RecipeInput,
) -> Result<String, RecipeError> {
    use crate::generated::{create_recipe as create_recipe_operation, CreateRecipe};

    let data =
        graphql_request::<CreateRecipe>(create_recipe_operation::Variables { input }).await?;
    data.create_recipe
        .map(|recipe| recipe.id)
        .ok_or_else(|| RecipeError::Other("no recipe created".to_string()))
}
