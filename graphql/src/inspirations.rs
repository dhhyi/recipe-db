use async_graphql::{Context, Error, Object};
use reqwest::StatusCode;

use crate::rest_client::RestClient;

pub struct InspirationsApi {
    client: RestClient,
}

impl InspirationsApi {
    pub fn new() -> Self {
        Self {
            client: RestClient::new("inspirations"),
        }
    }

    pub async fn delete_inspirations_for_testing(&self) -> Result<bool, Error> {
        self.client.delete("/").await?;
        Ok(true)
    }

    pub async fn get_inspirations(&self, id: &str) -> Result<Vec<String>, Error> {
        match self.client.get(id).await {
            Ok(urls) => Ok(urls),
            Err(err) if err.status == StatusCode::NOT_FOUND => Ok(Vec::new()),
            Err(err) => Err(err.into()),
        }
    }

    /// Empty/absent data clears any existing inspirations, otherwise replaces them.
    pub async fn set_inspirations(&self, id: &str, inspirations: &[String]) -> Result<(), Error> {
        if inspirations.is_empty() {
            match self.client.get::<serde_json::Value>(id).await {
                Ok(_) => self.client.delete(id).await.map_err(Into::into),
                Err(err) if err.status == StatusCode::NOT_FOUND => Ok(()),
                Err(err) => Err(err.into()),
            }
        } else {
            self.client
                .put::<_, serde_json::Value>(id, &inspirations)
                .await?;
            Ok(())
        }
    }
}

#[derive(Default)]
pub struct InspirationsMutation;

#[Object]
impl InspirationsMutation {
    async fn delete_inspirations_for_testing(&self, ctx: &Context<'_>) -> Result<bool, Error> {
        ctx.data::<InspirationsApi>()?
            .delete_inspirations_for_testing()
            .await
    }
}
