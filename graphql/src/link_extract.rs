use crate::link::ExtractedLink;
use crate::rest_client::RestClient;

pub struct LinkExtractApi {
    client: RestClient,
}

impl LinkExtractApi {
    pub fn new() -> Self {
        Self {
            client: RestClient::new("link-extract"),
        }
    }

    pub async fn get_extracted_link(&self, url: &str) -> Option<ExtractedLink> {
        let mut link: ExtractedLink = self.client.get_with_query("", &[("url", url)]).await.ok()?;
        if link.canonical.is_none() {
            link.canonical = Some(url.to_string());
        }
        Some(link)
    }
}
