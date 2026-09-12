use async_graphql::{Context, Error, Object, SimpleObject, ID};
use serde::Deserialize;

use crate::rest_client::{RestClient, RestError};

#[derive(Clone, Debug, Deserialize, SimpleObject)]
#[serde(rename_all = "camelCase")]
pub struct Rating {
    pub recipe_id: async_graphql::ID,
    pub average: Option<f64>,
    pub count: Option<i32>,
}

#[derive(Deserialize)]
struct RestRating {
    rating: f64,
    count: i32,
}

pub struct RatingsApi {
    client: RestClient,
}

impl RatingsApi {
    pub fn new() -> Self {
        Self {
            client: RestClient::new("ratings"),
        }
    }

    pub async fn delete_ratings_for_testing(&self) -> Result<bool, Error> {
        self.client
            .delete("")
            .await
            .map_err(RestError::into_error)?;
        Ok(true)
    }

    pub async fn get_rating(&self, id: &str) -> Result<Rating, Error> {
        let rating: RestRating = self.client.get(id).await.map_err(RestError::into_error)?;
        Ok(Rating {
            recipe_id: ID::from(id.to_string()),
            average: Some(rating.rating),
            count: Some(rating.count),
        })
    }

    pub async fn add_rating(&self, id: &str, rating: i32, login: &str) -> Result<Rating, Error> {
        let body = format!("rating={rating}&login={login}");
        let result: RestRating = self
            .client
            .put_form(id, body)
            .await
            .map_err(RestError::into_error)?;
        Ok(Rating {
            recipe_id: ID::from(id.to_string()),
            average: Some(result.rating),
            count: Some(result.count),
        })
    }
}

#[derive(Default)]
pub struct RatingsQuery;

#[Object]
impl RatingsQuery {
    async fn rating(&self, ctx: &Context<'_>, id: ID) -> Result<Rating, Error> {
        ctx.data::<RatingsApi>()?.get_rating(id.as_str()).await
    }
}

#[derive(Default)]
pub struct RatingsMutation;

#[Object]
impl RatingsMutation {
    async fn delete_ratings_for_testing(&self, ctx: &Context<'_>) -> Result<bool, Error> {
        ctx.data::<RatingsApi>()?.delete_ratings_for_testing().await
    }

    async fn rate(
        &self,
        ctx: &Context<'_>,
        id: ID,
        rating: i32,
        login: String,
    ) -> Result<Rating, Error> {
        ctx.data::<RatingsApi>()?
            .add_rating(id.as_str(), rating, &login)
            .await
    }
}
