use async_graphql::{ComplexObject, Context, InputValueError, InputValueResult, Value};
use async_graphql::{InputObject, Scalar, ScalarType, SimpleObject};
use serde::{Deserialize, Serialize};

use crate::images::ImagesApi;
use crate::inspirations::InspirationsApi;
use crate::ratings::RatingsApi;

/// Custom scalar accepting either a JSON number or string, matching `recipe-db.graphqls`'s
/// `StringOrInt` (used for ingredient amounts like `"1"` or `1`).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct StringOrInt(pub serde_json::Value);

#[Scalar(name = "StringOrInt")]
impl ScalarType for StringOrInt {
    fn parse(value: Value) -> InputValueResult<Self> {
        match value {
            Value::String(s) => Ok(StringOrInt(serde_json::Value::String(s))),
            Value::Number(n) => n
                .as_i64()
                .map(|i| StringOrInt(serde_json::json!(i)))
                .or_else(|| n.as_f64().map(|f| StringOrInt(serde_json::json!(f))))
                .ok_or_else(|| InputValueError::custom("invalid number")),
            _ => Err(InputValueError::expected_type(value)),
        }
    }

    fn to_value(&self) -> Value {
        match &self.0 {
            serde_json::Value::String(s) => Value::String(s.clone()),
            serde_json::Value::Number(n) => n
                .as_i64()
                .map(|i| Value::Number(i.into()))
                .or_else(|| {
                    n.as_f64()
                        .and_then(async_graphql::Number::from_f64)
                        .map(Value::Number)
                })
                .unwrap_or(Value::Null),
            _ => Value::Null,
        }
    }
}

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
    Ok(value.map(|value| match value {
        serde_json::Value::String(s) => s,
        other => other.to_string(),
    }))
}

#[derive(Clone, Debug, Serialize, Deserialize, InputObject)]
pub struct IngredientInput {
    pub amount: Option<StringOrInt>,
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
    pub method: Option<String>,
    pub ingredients: Option<Vec<Ingredient>>,
}

#[ComplexObject]
impl Recipe {
    /// `null` means the ratings service is unavailable (it always returns a zero-valued rating
    /// for an unknown id, so this is never `null` just because there's "no rating yet").
    async fn rating(
        &self,
        ctx: &Context<'_>,
    ) -> async_graphql::Result<Option<crate::ratings::Rating>> {
        match ctx.data::<RatingsApi>()?.get_rating(self.id.as_str()).await {
            Ok(rating) => Ok(Some(rating)),
            Err(err) => {
                eprintln!("ratings service unavailable: {err:?}");
                Ok(None)
            }
        }
    }

    async fn image(
        &self,
        ctx: &Context<'_>,
    ) -> async_graphql::Result<Option<crate::images::ImageMetadata>> {
        Ok(ctx
            .data::<ImagesApi>()?
            .get_image_metadata(self.id.as_str())
            .await)
    }

    /// `null` means the inspirations service is unavailable (as opposed to `[]`, which means the
    /// service is up and the recipe simply has no inspirations).
    async fn inspirations(
        &self,
        ctx: &Context<'_>,
    ) -> async_graphql::Result<Option<Vec<crate::link::Link>>> {
        match ctx
            .data::<InspirationsApi>()?
            .get_inspirations(self.id.as_str())
            .await
        {
            Ok(urls) => Ok(Some(
                urls.into_iter()
                    .map(|url| crate::link::Link { url })
                    .collect(),
            )),
            Err(err) => {
                eprintln!("inspirations service unavailable: {err:?}");
                Ok(None)
            }
        }
    }
}
