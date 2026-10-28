use async_graphql::{Context, Error, Json, Object, SimpleObject};
use futures::future::try_join_all;
use serde::Deserialize;
use serde_json::Value;

use crate::recipe::Recipe;
use crate::recipes::RecipesApi;
use crate::rest_client::{RestClient, RestError};

pub struct SearchApi {
    client: RestClient,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SearchResponse {
    recipe_ids: Vec<String>,
    found: i32,
    page: i32,
    per_page: i32,
    facet_counts: Value,
}

impl SearchApi {
    pub fn new() -> Self {
        Self {
            client: RestClient::new("search"),
        }
    }

    async fn search(&self, options: &Value) -> Result<SearchResponse, Error> {
        self.client
            .post("", options)
            .await
            .map_err(RestError::into_error)
    }
}

#[derive(SimpleObject)]
pub struct RecipeSearchResult {
    recipes: Vec<Recipe>,
    found: i32,
    page: i32,
    per_page: i32,
    facets: Json<Value>,
}

#[derive(Default)]
pub struct SearchQuery;

#[Object]
impl SearchQuery {
    async fn search_recipes(
        &self,
        ctx: &Context<'_>,
        options: Json<Value>,
    ) -> Result<RecipeSearchResult, Error> {
        ctx.data::<crate::auth::RequestContext>()?
            .require(crate::auth::Capability::ReadPublic)
            .map_err(crate::auth::AuthorizationError::into_graphql_error)?;
        let result = ctx.data::<SearchApi>()?.search(&options.0).await?;
        let recipes_api = ctx.data::<RecipesApi>()?;
        let recipes = try_join_all(
            result
                .recipe_ids
                .iter()
                .map(|id| recipes_api.get_recipe(id)),
        )
        .await?;

        Ok(RecipeSearchResult {
            recipes: recipes.into_iter().flatten().collect(),
            found: result.found,
            page: result.page,
            per_page: result.per_page,
            facets: Json(result.facet_counts),
        })
    }
}
