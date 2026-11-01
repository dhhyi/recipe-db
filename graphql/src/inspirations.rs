use crate::events::{EventKind, EventPublisher};
use crate::rest_client::{RestClient, RestError};
use async_graphql::Error;

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
            Err(err) if err.confirms_absence("inspiration-not-found") => Ok(Vec::new()),
            Err(err) => Err(err.into_error()),
        }
    }

    /// Empty/absent data clears any existing inspirations, otherwise replaces them.
    pub async fn set_inspirations(
        &self,
        id: &str,
        inspirations: &[String],
        publisher: &EventPublisher,
    ) -> Result<bool, Error> {
        if inspirations.is_empty() {
            match self.client.get::<serde_json::Value>(id).await {
                Ok(_) => self
                    .client
                    .delete(id)
                    .await
                    .map_err(RestError::into_error)?,
                Err(err) if err.confirms_absence("inspiration-not-found") => return Ok(false),
                Err(err) => return Err(err.into_error()),
            }
        } else {
            self.client
                .put::<_, serde_json::Value>(id, &inspirations)
                .await
                .map_err(RestError::into_error)?;
        }
        publisher.notify(id, EventKind::InspirationsChanged).await;
        Ok(true)
    }
}
