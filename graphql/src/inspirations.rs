use async_graphql::Error;
use reqwest::StatusCode;

use crate::events::{EventKind, EventPublisher};
use crate::rest_client::{RestClient, RestError};

pub struct InspirationsApi {
    client: RestClient,
}

impl InspirationsApi {
    pub fn new() -> Self {
        Self {
            client: RestClient::new("inspirations"),
        }
    }

    pub async fn get_inspirations(&self, id: &str) -> Result<Vec<String>, Error> {
        match self.client.get(id).await {
            Ok(urls) => Ok(urls),
            Err(err) if err.status == StatusCode::NOT_FOUND => Ok(Vec::new()),
            Err(err) => Err(err.into_error()),
        }
    }

    /// Empty/absent data clears any existing inspirations, otherwise replaces them.
    pub async fn set_inspirations(
        &self,
        id: &str,
        inspirations: &[String],
        publisher: &EventPublisher,
    ) -> Result<(), Error> {
        if inspirations.is_empty() {
            match self.client.get::<serde_json::Value>(id).await {
                Ok(_) => self
                    .client
                    .delete(id)
                    .await
                    .map_err(RestError::into_error)?,
                Err(err) if err.status == StatusCode::NOT_FOUND => return Ok(()),
                Err(err) => return Err(err.into_error()),
            }
        } else {
            self.client
                .put::<_, serde_json::Value>(id, &inspirations)
                .await
                .map_err(RestError::into_error)?;
        }
        publisher
            .notify(Some(id), EventKind::InspirationsChanged)
            .await;
        Ok(())
    }
}
