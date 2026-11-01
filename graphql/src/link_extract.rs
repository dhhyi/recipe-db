use crate::link::ExtractedLink;
use async_graphql::Error;

use crate::rest_client::{RestClient, RestError};

pub struct LinkExtractApi {
    client: RestClient,
}

impl LinkExtractApi {
    pub fn new() -> Self {
        Self {
            client: RestClient::new("link-extract"),
        }
    }

    pub async fn get_extracted_link(&self, url: &str) -> Result<Option<ExtractedLink>, Error> {
        let mut link: ExtractedLink = self
            .client
            .get_with_query("", &[("url", url)])
            .await
            .map_err(RestError::into_error)?;
        if link.canonical.is_none() {
            link.canonical = Some(url.to_string());
        }
        Ok(Some(link))
    }
}
