use async_graphql::{
    ComplexObject, Context, Error, ErrorExtensions, Json, Object, SimpleObject, ID,
};
use futures::future::join_all;
use serde::Deserialize;
use serde_json::Value;
use std::collections::HashSet;

use crate::recipe::Recipe;
use crate::recipes::RecipesApi;
use crate::rest_client::{RestClient, RestError};
use crate::tags::TagsApi;

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

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SimilarSearchResponse {
    recipe_ids: Vec<String>,
    found: u64,
    page: u64,
    per_page: u64,
    #[serde(alias = "search_cutoff")]
    search_cutoff: bool,
    #[serde(default)]
    error: Option<Value>,
}

fn filter_literal(id: &str) -> Result<String, Error> {
    // Typesense 29 does not reliably escape these in ID exclusion filters.
    if id.is_empty()
        || id
            .chars()
            .any(|c| c.is_control() || matches!(c, '\\' | '`'))
    {
        return Err(Error::new(
            "Identifier cannot be represented safely as a Typesense filter literal",
        ));
    }
    Ok(format!("`{id}`"))
}

fn similar_options(recipe_id: &str, tag_ids: &[&str]) -> Result<Value, Error> {
    // Typesense's query syntax treats these as operators, not opaque ID text.
    if tag_ids.iter().any(|id| {
        id.is_empty()
            || id.starts_with('-')
            || id
                .chars()
                .any(|c| c.is_whitespace() || c.is_control() || matches!(c, '*' | '"'))
    }) {
        return Err(Error::new(
            "Tag ID cannot be represented as a Typesense identifier query",
        ));
    }
    let tags = tag_ids
        .iter()
        .map(|id| filter_literal(id))
        .collect::<Result<Vec<_>, _>>()?
        .join(",");
    let source = filter_literal(recipe_id)?;
    Ok(serde_json::json!({
        "q": tag_ids.join(" "),
        "query_by": "tag_ids",
        "filter_by": format!("tag_ids:=[{tags}] && id:!={source}"),
        "sort_by": "_text_match:desc,recipe_id_sort:asc",
        "prefix": false,
        "num_typos": 0,
        "split_join_tokens": "off",
        "per_page": 100,
        "page": 1
    }))
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

    async fn similar_ids(&self, mut options: Value, source: &str) -> Result<Vec<ID>, Error> {
        let mut ids = Vec::new();
        let mut seen = HashSet::new();
        let mut page = 1u64;
        let mut received = 0u64;
        let mut found = None;
        loop {
            options["page"] = page.into();
            let result: SimilarSearchResponse = self
                .client
                .post("", &options)
                .await
                .map_err(RestError::into_error)?;
            let count = result.recipe_ids.len() as u64;
            if result.search_cutoff {
                return Err(
                    Error::new("Similarity search was cut off before completion").extend_with(
                        |_, extensions| {
                            extensions.set("code", "search-cutoff");
                            extensions.set("status", 503);
                        },
                    ),
                );
            }
            // Pagination is not a snapshot. A changing total requires retrying the whole capture.
            if result.error.is_some()
                || result.page != page
                || result.per_page != 100
                || found.is_some_and(|found| found != result.found)
                || count > 100
                || received.checked_add(count).is_none()
                || received + count > result.found
                || (count < 100 && received + count < result.found)
            {
                return Err(Error::new(
                    "Similarity search returned incomplete or invalid results",
                ));
            }
            found = Some(result.found);
            received += count;
            let previous_len = ids.len();
            for id in result.recipe_ids {
                if id.is_empty() || id == source {
                    return Err(Error::new(
                        "Similarity search returned an invalid recipe ID",
                    ));
                }
                if seen.insert(id.clone()) {
                    ids.push(ID(id));
                }
            }
            if received == result.found {
                return Ok(ids);
            }
            if ids.len() == previous_len {
                return Err(Error::new("Similarity search made no progress"));
            }
            page = page
                .checked_add(1)
                .ok_or_else(|| Error::new("Similarity search page overflow"))?;
        }
    }
}

#[derive(SimpleObject)]
#[graphql(complex)]
pub struct RecipeSearchResult {
    #[graphql(skip)]
    recipe_ids: Vec<String>,
    found: i32,
    page: i32,
    per_page: i32,
    facets: Json<Value>,
}

#[ComplexObject]
impl RecipeSearchResult {
    async fn recipes(&self, ctx: &Context<'_>) -> Vec<Option<Recipe>> {
        let api = match ctx.data::<RecipesApi>() {
            Ok(api) => api,
            Err(error) => {
                let mut error = error.into_server_error(ctx.item.pos);
                error = ctx.set_error_path(error);
                ctx.add_error(error);
                return vec![None; self.recipe_ids.len()];
            }
        };
        let results = join_all(self.recipe_ids.iter().map(|id| api.get_recipe(id))).await;
        results
            .into_iter()
            .enumerate()
            .map(|(index, result)| match result {
                Ok(recipe) => recipe,
                Err(error) => {
                    let mut error = error.into_server_error(ctx.item.pos);
                    error = ctx.set_error_path(error);
                    error.path.push(async_graphql::PathSegment::Index(index));
                    ctx.add_error(error);
                    None
                }
            })
            .collect()
    }
}

#[derive(Default)]
pub struct SearchQuery;

#[Object]
impl SearchQuery {
    async fn similar_recipe_ids(
        &self,
        ctx: &Context<'_>,
        recipe_id: ID,
    ) -> Option<Result<Vec<ID>, Error>> {
        Some(
            async {
                ctx.data::<crate::auth::RequestContext>()?
                    .require(crate::auth::Capability::ReadPublic)
                    .map_err(crate::auth::AuthorizationError::into_graphql_error)?;
                if ctx
                    .data::<RecipesApi>()?
                    .get_recipe(recipe_id.as_str())
                    .await?
                    .is_none()
                {
                    return Err(Error::new("Recipe does not exist.").extend_with(
                        |_, extensions| {
                            extensions.set("code", "recipe-not-found");
                            extensions.set("status", 404);
                            extensions.set("field", "recipeId");
                        },
                    ));
                }
                let tags = ctx
                    .data::<TagsApi>()?
                    .recipe_tags(recipe_id.as_str())
                    .await?;
                if tags.is_empty() {
                    return Ok(Vec::new());
                }
                let tag_ids = tags.iter().map(|tag| tag.id.as_str()).collect::<Vec<_>>();
                let options = similar_options(recipe_id.as_str(), &tag_ids)?;
                ctx.data::<SearchApi>()?
                    .similar_ids(options, recipe_id.as_str())
                    .await
            }
            .await,
        )
    }

    async fn search_recipes(
        &self,
        ctx: &Context<'_>,
        options: Json<Value>,
    ) -> Option<Result<RecipeSearchResult, Error>> {
        let request = match ctx.data::<crate::auth::RequestContext>() {
            Ok(request) => request,
            Err(error) => return Some(Err(error)),
        };
        if let Err(error) = request.require(crate::auth::Capability::ReadPublic) {
            return Some(Err(error.into_graphql_error()));
        }
        Some(
            async {
                let result = ctx.data::<SearchApi>()?.search(&options.0).await?;
                Ok(RecipeSearchResult {
                    recipe_ids: result.recipe_ids,
                    found: result.found,
                    page: result.page,
                    per_page: result.per_page,
                    facets: Json(result.facet_counts),
                })
            }
            .await,
        )
    }
}

#[cfg(test)]
#[path = "search_test.rs"]
mod tests;
