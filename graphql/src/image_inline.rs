use async_graphql::Error;

use crate::rest_client::{RestClient, RestError};

pub struct ImageInlineApi {
    client: RestClient,
}

impl ImageInlineApi {
    pub fn new(ignored: crate::ignored_services::IgnoredServices) -> Self {
        Self {
            client: RestClient::new("image-inline").with_ignored_services(ignored),
        }
    }

    pub async fn get_inlined_image(&self, url: &str) -> Result<String, Error> {
        self.client
            .get_text_with_query("/", &[("url", url)])
            .await
            .map_err(RestError::into_error)
    }
}
