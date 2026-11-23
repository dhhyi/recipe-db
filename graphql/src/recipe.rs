use async_graphql::{ComplexObject, Context, Error};
use async_graphql::{InputObject, SimpleObject};
use serde::{Deserialize, Serialize};

use crate::images::ImagesApi;
use crate::inspirations::InspirationsApi;
use crate::ratings::RatingsApi;

#[cfg(test)]
#[path = "recipe_test.rs"]
mod tests;

#[derive(Clone, Debug, Serialize, Deserialize, SimpleObject)]
pub struct Ingredient {
    #[serde(default, deserialize_with = "deserialize_lenient_string")]
    pub amount: Option<String>,
    pub name: String,
    pub optional: Option<bool>,
    pub unit: Option<String>,
}

/// The `recipes` REST backend is schemaless and echoes back whatever JSON type was stored for
/// `amount` (string or number), while the GraphQL field is a plain `String`.
fn deserialize_lenient_string<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = Option::<serde_json::Value>::deserialize(deserializer)?;
    Ok(match value {
        Some(serde_json::Value::String(value)) => Some(value),
        Some(serde_json::Value::Number(value)) => Some(value.to_string()),
        _ => None,
    })
}

#[derive(Clone, Debug, Serialize, Deserialize, InputObject)]
pub struct IngredientInput {
    pub amount: Option<String>,
    pub name: String,
    pub optional: Option<bool>,
    pub unit: Option<String>,
}

#[derive(Debug, Default, InputObject)]
pub struct RecipeInput {
    pub ingredients: async_graphql::MaybeUndefined<Vec<IngredientInput>>,
    pub method: async_graphql::MaybeUndefined<String>,
    pub name: async_graphql::MaybeUndefined<String>,
    pub inspirations: async_graphql::MaybeUndefined<Vec<String>>,
}

fn insert_maybe_undefined<T: Serialize>(
    map: &mut serde_json::Map<String, serde_json::Value>,
    key: &str,
    value: &async_graphql::MaybeUndefined<T>,
) {
    match value {
        async_graphql::MaybeUndefined::Undefined => {}
        async_graphql::MaybeUndefined::Null => {
            map.insert(key.to_string(), serde_json::Value::Null);
        }
        async_graphql::MaybeUndefined::Value(value) => {
            map.insert(key.to_string(), serde_json::to_value(value).unwrap());
        }
    }
}

impl RecipeInput {
    /// Only the fields the `recipes` REST backend itself owns - `inspirations` is applied
    /// separately via `InspirationsApi`. A key is included (possibly as JSON `null`) only if the
    /// client actually sent it - matching the backend's partial-update semantics, where an
    /// explicit `null`/empty `name` is rejected but an *omitted* `name` leaves it untouched.
    pub fn base(&self) -> serde_json::Value {
        let mut map = serde_json::Map::new();
        insert_maybe_undefined(&mut map, "ingredients", &self.ingredients);
        insert_maybe_undefined(&mut map, "method", &self.method);
        insert_maybe_undefined(&mut map, "name", &self.name);
        serde_json::Value::Object(map)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, SimpleObject)]
#[graphql(complex)]
pub struct Recipe {
    pub id: async_graphql::ID,
    pub name: String,
    #[serde(rename = "nameSortKey")]
    pub name_sort_key: String,
    pub method: Option<String>,
    pub ingredients: Option<Vec<Ingredient>>,
    /// UTC RFC 3339 timestamp with microsecond precision.
    #[serde(rename = "createdAt")]
    pub created_at: String,
    /// UTC RFC 3339 timestamp with microsecond precision.
    #[serde(rename = "updatedAt")]
    pub updated_at: String,
}

#[ComplexObject]
impl Recipe {
    /// `null` means the ratings service is unavailable (it always returns a zero-valued rating
    /// for an unknown id, so this is never `null` just because there's "no rating yet").
    async fn rating(
        &self,
        ctx: &Context<'_>,
    ) -> Option<async_graphql::Result<crate::ratings::Rating>> {
        let request = match ctx.data::<crate::auth::RequestContext>() {
            Ok(request) => request,
            Err(error) => return Some(Err(error)),
        };
        if let Err(error) = request.require(crate::auth::Capability::ReadAggregateRatings) {
            return Some(Err(error.into_graphql_error()));
        }
        Some(async { ctx.data::<RatingsApi>()?.get_rating(self.id.as_str()).await }.await)
    }

    async fn image(
        &self,
        ctx: &Context<'_>,
    ) -> Option<async_graphql::Result<Option<crate::images::ImageMetadata>>> {
        let request = match ctx.data::<crate::auth::RequestContext>() {
            Ok(request) => request,
            Err(error) => return Some(Err(error)),
        };
        if let Err(error) = request.require(crate::auth::Capability::ReadPublic) {
            return Some(Err(error.into_graphql_error()));
        }
        Some(
            async {
                ctx.data::<ImagesApi>()?
                    .get_image_metadata(self.id.as_str())
                    .await
            }
            .await,
        )
    }

    async fn images(
        &self,
        ctx: &Context<'_>,
    ) -> Option<async_graphql::Result<Vec<crate::images::ImageMetadata>>> {
        let request = match ctx.data::<crate::auth::RequestContext>() {
            Ok(request) => request,
            Err(error) => return Some(Err(error)),
        };
        if let Err(error) = request.require(crate::auth::Capability::ReadPublic) {
            return Some(Err(error.into_graphql_error()));
        }
        Some(
            async {
                ctx.data::<ImagesApi>()?
                    .get_image_collection(self.id.as_str())
                    .await
            }
            .await,
        )
    }

    /// `null` means the inspirations service is unavailable (as opposed to `[]`, which means the
    /// service is up and the recipe simply has no inspirations).
    async fn inspirations(
        &self,
        ctx: &Context<'_>,
    ) -> Option<async_graphql::Result<Vec<crate::link::Link>>> {
        let request = match ctx.data::<crate::auth::RequestContext>() {
            Ok(request) => request,
            Err(error) => return Some(Err(error)),
        };
        if let Err(error) = request.require(crate::auth::Capability::ReadPublic) {
            return Some(Err(error.into_graphql_error()));
        }
        Some(
            async {
                ctx.data::<InspirationsApi>()?
                    .get_inspirations(self.id.as_str())
                    .await
                    .map(|urls| {
                        urls.into_iter()
                            .map(|url| crate::link::Link { url })
                            .collect()
                    })
            }
            .await,
        )
    }

    /// `null` means the tags service is unavailable; a successful empty response is `[]`.
    async fn tags(&self, ctx: &Context<'_>) -> Option<Result<Vec<crate::tags::Tag>, Error>> {
        let request = match ctx.data::<crate::auth::RequestContext>() {
            Ok(request) => request,
            Err(error) => return Some(Err(error)),
        };
        if let Err(error) = request.require(crate::auth::Capability::ReadPublic) {
            return Some(Err(error.into_graphql_error()));
        }
        Some(
            async {
                ctx.data::<crate::tags::TagsApi>()?
                    .recipe_tags(self.id.as_str())
                    .await
            }
            .await,
        )
    }
}
