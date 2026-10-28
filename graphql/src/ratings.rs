use async_graphql::{ComplexObject, Context, Error, Object, SimpleObject, ID};
use serde::Deserialize;

use crate::events::{EventKind, EventPublisher};
use crate::rest_client::{RestClient, RestError};

#[derive(Clone, Debug, Deserialize, SimpleObject)]
#[graphql(complex)]
#[serde(rename_all = "camelCase")]
pub struct Rating {
    pub recipe_id: async_graphql::ID,
    pub average: Option<f64>,
    pub count: Option<i32>,
}

#[ComplexObject]
impl Rating {
    async fn my_rating(&self, ctx: &Context<'_>) -> Result<Option<i32>, Error> {
        let request = ctx.data::<crate::auth::RequestContext>()?;
        if let Err(error) = request.require(crate::auth::Capability::ReadIndividualRatings) {
            let error = error.into_graphql_error().into_server_error(ctx.item.pos);
            ctx.add_error(ctx.set_error_path(error));
            return Ok(None);
        }
        ctx.data::<RatingsApi>()?
            .get_user_rating(self.recipe_id.as_str(), request.principal().id().as_str())
            .await
    }
}

#[derive(Deserialize)]
struct RestRating {
    rating: f64,
    count: i32,
}

#[derive(Deserialize)]
struct RestUserRating {
    rating: Option<i32>,
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

    pub async fn get_rating(&self, id: &str) -> Result<Rating, Error> {
        let rating: RestRating = self.client.get(id).await.map_err(RestError::into_error)?;
        Ok(Rating {
            recipe_id: ID::from(id.to_string()),
            average: Some(rating.rating),
            count: Some(rating.count),
        })
    }

    pub async fn get_user_rating(&self, id: &str, user_id: &str) -> Result<Option<i32>, Error> {
        let result: RestUserRating = self
            .client
            .get_with_query(id, &[("userId", user_id)])
            .await
            .map_err(RestError::into_error)?;
        Ok(result.rating)
    }

    pub async fn add_rating(
        &self,
        id: &str,
        rating: i32,
        user_id: &str,
        publisher: &EventPublisher,
    ) -> Result<Rating, Error> {
        let rating = rating.to_string();
        let result: RestRating = self
            .client
            .put_form(id, &[("rating", rating.as_str()), ("userId", user_id)])
            .await
            .map_err(RestError::into_error)?;
        publisher.notify(Some(id), EventKind::RatingChanged).await;
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
        ctx.data::<crate::auth::RequestContext>()?
            .require(crate::auth::Capability::ReadAggregateRatings)
            .map_err(crate::auth::AuthorizationError::into_graphql_error)?;
        ctx.data::<RatingsApi>()?.get_rating(id.as_str()).await
    }
}

#[derive(Default)]
pub struct RatingsMutation;

#[Object]
impl RatingsMutation {
    async fn rate(&self, ctx: &Context<'_>, id: ID, rating: i32) -> Result<Rating, Error> {
        let request = ctx.data::<crate::auth::RequestContext>()?;
        request
            .require(crate::auth::Capability::WriteRatings)
            .map_err(crate::auth::AuthorizationError::into_graphql_error)?;
        ctx.data::<RatingsApi>()?
            .add_rating(
                id.as_str(),
                rating,
                request.principal().id().as_str(),
                ctx.data::<EventPublisher>()?,
            )
            .await
    }
}
