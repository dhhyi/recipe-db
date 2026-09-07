use async_graphql::{Context, Error, Object};
use serde::Deserialize;

use crate::rest_client::RestClient;

#[derive(Deserialize)]
struct TraefikRouter {
    name: String,
    service: String,
    provider: String,
    #[serde(rename = "entryPoints")]
    entry_points: Vec<String>,
}

#[derive(Deserialize)]
struct TraefikService {
    name: String,
    provider: String,
    #[serde(rename = "serverStatus", default)]
    server_status: std::collections::HashMap<String, String>,
}

fn trimmed_name(name: &str, provider: &str) -> String {
    name.replace(provider, "").trim_end_matches('@').to_string()
}

pub struct TraefikApi {
    client: RestClient,
    entry_points: Vec<String>,
}

impl TraefikApi {
    pub fn new() -> Self {
        Self {
            client: RestClient::new("api/http"),
            entry_points: std::env::var("TRAEFIK_ENTRYPOINTS")
                .unwrap_or_default()
                .split(',')
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect(),
        }
    }

    async fn get_routers(&self) -> Result<Vec<TraefikRouter>, Error> {
        Ok(self.client.get("routers").await?)
    }

    async fn get_services(&self) -> Result<Vec<TraefikService>, Error> {
        Ok(self.client.get("services").await?)
    }

    pub async fn get_online_services(&self) -> Result<Vec<String>, Error> {
        let services = self.get_services().await?;
        let routers = self.get_routers().await?;

        let online_services: Vec<String> = services
            .into_iter()
            .filter(|service| service.server_status.values().any(|status| status == "UP"))
            .map(|service| trimmed_name(&service.name, &service.provider))
            .collect();

        Ok(routers
            .into_iter()
            .filter(|router| {
                router
                    .entry_points
                    .iter()
                    .any(|ep| self.entry_points.contains(ep))
            })
            .filter(|router| online_services.contains(&router.service))
            .map(|router| trimmed_name(&router.name, &router.provider))
            .collect())
    }
}

#[derive(Default)]
pub struct TraefikQuery;

#[Object]
impl TraefikQuery {
    async fn online_services(&self, ctx: &Context<'_>) -> Result<Vec<String>, Error> {
        ctx.data::<TraefikApi>()?.get_online_services().await
    }

    async fn is_service_online(&self, ctx: &Context<'_>, name: String) -> Result<bool, Error> {
        let online = ctx.data::<TraefikApi>()?.get_online_services().await?;
        Ok(online.contains(&name))
    }

    async fn all_services_online(
        &self,
        ctx: &Context<'_>,
        names: Vec<String>,
    ) -> Result<bool, Error> {
        let online = ctx.data::<TraefikApi>()?.get_online_services().await?;
        Ok(names.iter().all(|name| online.contains(name)))
    }
}
