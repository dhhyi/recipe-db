use async_graphql::Error;

use crate::rest_client::RestClient;

pub struct ImageInlineApi {
    client: RestClient,
}

impl ImageInlineApi {
    pub fn new() -> Self {
        Self {
            client: RestClient::new("image-inline"),
        }
    }

    pub async fn get_inlined_image(&self, url: &str) -> Result<String, Error> {
        Ok(self
            .client
            .get_text_with_query("/", &[("url", url)])
            .await?)
    }
}
