use async_graphql::{Context, Error, ErrorExtensions, Object, ID};
use reqwest::StatusCode;
use serde::Deserialize;

use crate::recipe::{Recipe, RecipeInput};
use crate::rest_client::{RestClient, RestError};

#[derive(Deserialize)]
struct ProblemDetails {
    detail: String,
    code: String,
    field: Option<String>,
}

/// The recipes service rejects a missing/empty name with a 422 - surface it as the same
/// `BAD_USER_INPUT`/`field: name` shape the frontend/graphql-test expect.
fn rethrow_as_validation_error(err: RestError) -> Error {
    if err.status == StatusCode::UNPROCESSABLE_ENTITY {
        if let Ok(problem) = serde_json::from_str::<ProblemDetails>(&err.body) {
            if problem.code == "invalid-field" && problem.field.as_deref() == Some("name") {
                return Error::new(problem.detail).extend_with(|_, e| {
                    e.set("code", "BAD_USER_INPUT");
                    e.set("field", "name");
                });
            }
        }
    }
    err.into()
}

pub struct RecipesApi {
    client: RestClient,
}

impl RecipesApi {
    pub fn new() -> Self {
        Self {
            client: RestClient::new("recipes"),
        }
    }

    pub async fn delete_recipes_for_testing(&self) -> Result<bool, Error> {
        self.client.delete("").await?;
        Ok(true)
    }

    pub async fn get_recipes(&self) -> Result<Vec<Recipe>, Error> {
        Ok(self.client.get("").await?)
    }

    pub async fn get_recipe(&self, id: &str) -> Result<Option<Recipe>, Error> {
        match self.client.get(id).await {
            Ok(recipe) => Ok(Some(recipe)),
            Err(err) if err.status == StatusCode::NOT_FOUND => Ok(None),
            Err(err) => Err(err.into()),
        }
    }

    pub async fn create_recipe(&self, value: &RecipeInput) -> Result<Recipe, Error> {
        self.client
            .post("", &value.base())
            .await
            .map_err(rethrow_as_validation_error)
    }

    pub async fn update_recipe(&self, id: &str, value: &RecipeInput) -> Result<Recipe, Error> {
        self.client
            .patch(id, &value.base())
            .await
            .map_err(rethrow_as_validation_error)
    }

    pub async fn delete_recipe(&self, id: &str) -> Result<bool, Error> {
        match self.client.delete(id).await {
            Ok(()) => Ok(true),
            Err(err) if err.status == StatusCode::NOT_FOUND => Ok(false),
            Err(err) => Err(err.into()),
        }
    }
}

#[derive(Default)]
pub struct RecipesQuery;

#[Object]
impl RecipesQuery {
    async fn recipe(&self, ctx: &Context<'_>, id: ID) -> Result<Option<Recipe>, Error> {
        ctx.data::<RecipesApi>()?.get_recipe(id.as_str()).await
    }

    async fn recipes(&self, ctx: &Context<'_>) -> Result<Vec<Recipe>, Error> {
        ctx.data::<RecipesApi>()?.get_recipes().await
    }
}

#[derive(Default)]
pub struct RecipesMutation;

/// `Undefined` leaves inspirations untouched, `Null` clears them, `Value` replaces them -
/// mirrors the recipes REST backend's partial-update semantics for a present-vs-absent field.
async fn apply_inspirations(
    ctx: &Context<'_>,
    id: &str,
    inspirations: &async_graphql::MaybeUndefined<Vec<String>>,
) -> Result<(), Error> {
    let inspirations_api = ctx.data::<crate::inspirations::InspirationsApi>()?;
    match inspirations {
        async_graphql::MaybeUndefined::Undefined => Ok(()),
        async_graphql::MaybeUndefined::Null => inspirations_api.set_inspirations(id, &[]).await,
        async_graphql::MaybeUndefined::Value(urls) => {
            inspirations_api.set_inspirations(id, urls).await
        }
    }
}

#[Object]
impl RecipesMutation {
    async fn delete_recipes_for_testing(&self, ctx: &Context<'_>) -> Result<bool, Error> {
        ctx.data::<RecipesApi>()?.delete_recipes_for_testing().await
    }

    // `Option<Result<T>>` (not `Result<Option<T>>`) is what makes async-graphql resolve this
    // nullable field to `null` on error without nulling out the whole response's `data`.
    async fn create_recipe(
        &self,
        ctx: &Context<'_>,
        value: RecipeInput,
    ) -> Option<Result<Recipe, Error>> {
        Some(
            async {
                let recipe = ctx.data::<RecipesApi>()?.create_recipe(&value).await?;
                apply_inspirations(ctx, recipe.id.as_str(), &value.inspirations).await?;
                Ok(recipe)
            }
            .await,
        )
    }

    async fn update_recipe(
        &self,
        ctx: &Context<'_>,
        id: ID,
        value: RecipeInput,
    ) -> Option<Result<Recipe, Error>> {
        Some(
            async {
                apply_inspirations(ctx, id.as_str(), &value.inspirations).await?;
                ctx.data::<RecipesApi>()?
                    .update_recipe(id.as_str(), &value)
                    .await
            }
            .await,
        )
    }

    async fn delete_recipe(&self, ctx: &Context<'_>, id: ID) -> Result<bool, Error> {
        ctx.data::<RecipesApi>()?.delete_recipe(id.as_str()).await
    }
}
