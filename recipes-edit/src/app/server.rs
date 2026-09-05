use crate::generated::recipe_by_id::RecipeByIdRecipe;
use leptos::prelude::*;

#[cfg(feature = "ssr")]
async fn graphql_request<Q: graphql_client::GraphQLQuery>(
    variables: Q::Variables,
) -> Result<Q::ResponseData, ServerFnError> {
    use graphql_client::Response;

    let endpoint =
        std::env::var("GRAPHQL_API").unwrap_or_else(|_| "http://traefik/graphql".to_string());

    let response: Response<Q::ResponseData> = reqwest::Client::new()
        .post(endpoint)
        .json(&Q::build_query(variables))
        .send()
        .await?
        .error_for_status()?
        .json()
        .await?;

    if let Some(errors) = response.errors.filter(|errors| !errors.is_empty()) {
        let messages = errors
            .into_iter()
            .map(|error| error.message)
            .collect::<Vec<_>>()
            .join("; ");
        return Err(ServerFnError::new(messages));
    }

    response
        .data
        .ok_or_else(|| ServerFnError::new("no data returned"))
}

// the app is mounted under /edit, so server functions have to live below that prefix as well
#[server(prefix = "/edit/api")]
pub async fn fetch_recipe(id: String) -> Result<Option<RecipeByIdRecipe>, ServerFnError> {
    use crate::generated::{recipe_by_id, RecipeById};

    let data = graphql_request::<RecipeById>(recipe_by_id::Variables { id }).await?;
    Ok(data.recipe)
}

#[server(prefix = "/edit/api")]
pub async fn save_recipe(
    id: String,
    input: crate::generated::update_recipe::RecipeInput,
) -> Result<(), ServerFnError> {
    use crate::generated::{update_recipe, UpdateRecipe};

    graphql_request::<UpdateRecipe>(update_recipe::Variables { id, input }).await?;
    Ok(())
}

#[server(prefix = "/edit/api")]
pub async fn create_recipe(
    input: crate::generated::create_recipe::RecipeInput,
) -> Result<String, ServerFnError> {
    use crate::generated::{create_recipe as create_recipe_operation, CreateRecipe};

    let data =
        graphql_request::<CreateRecipe>(create_recipe_operation::Variables { input }).await?;
    data.create_recipe
        .map(|recipe| recipe.id)
        .ok_or_else(|| ServerFnError::new("no recipe created"))
}
