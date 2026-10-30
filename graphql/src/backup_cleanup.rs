use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;

const ATTEMPTS: u8 = 3;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Debug)]
struct Service {
    name: String,
    port: u16,
    role: String,
    compact: bool,
}

#[derive(Debug, Deserialize)]
struct RecipeIds {
    #[serde(rename = "recipeIds")]
    recipe_ids: Vec<String>,
}

#[derive(Debug, Serialize)]
struct Operation {
    service: String,
    operation: String,
    recipe_ids: Vec<String>,
    count: usize,
    attempts: u8,
    unresolved_failures: Vec<String>,
}

#[derive(Default, Serialize)]
struct Summary {
    target: String,
    namespace: String,
    release: String,
    revision: String,
    operations: Vec<Operation>,
    unresolved_failures: Vec<String>,
}

#[derive(Debug)]
struct RemoteFailure {
    attempts: u8,
    detail: String,
}

fn required_env(name: &str) -> Result<String, String> {
    let value = std::env::var(name).map_err(|_| format!("Missing {name}"))?;
    if value.trim().is_empty() {
        return Err(format!("{name} must not be empty"));
    }
    Ok(value)
}

fn validate_target_namespace(target: &str, namespace: &str) -> Result<(), String> {
    if !matches!(target, "local" | "pi") {
        return Err("BACKUP_TARGET must be local or pi".to_owned());
    }
    if namespace.is_empty()
        || namespace.len() > 63
        || !namespace
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        || !namespace.as_bytes()[0].is_ascii_alphanumeric()
        || !namespace.as_bytes()[namespace.len() - 1].is_ascii_alphanumeric()
    {
        return Err("BACKUP_NAMESPACE must be a valid Kubernetes namespace".to_owned());
    }
    Ok(())
}

fn valid_hex(value: &str, lengths: &[usize]) -> bool {
    lengths.contains(&value.len()) && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn valid_release(value: &str) -> bool {
    value
        .strip_prefix("ghcr.io/dhhyi/recipe-db-releases@sha256:")
        .is_some_and(|digest| valid_hex(digest, &[64]))
}

fn parse_services(value: &str) -> Result<Vec<Service>, String> {
    let mut services = Vec::new();
    let mut seen = BTreeSet::new();
    for entry in value.split(',') {
        let fields = entry.split('|').collect::<Vec<_>>();
        if fields.len() != 4 {
            return Err("Invalid backup participant metadata".to_owned());
        }
        let name = fields[0];
        if name.is_empty()
            || !name
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
            || !seen.insert(name.to_owned())
        {
            return Err("Invalid or duplicate backup participant name".to_owned());
        }
        let port = fields[1]
            .parse::<u16>()
            .ok()
            .filter(|port| *port > 0)
            .ok_or_else(|| format!("Invalid service port for {name}"))?;
        let role = fields[2];
        if !matches!(
            role,
            "authoritative-read-only"
                | "cleanup-participant"
                | "derived-stateless"
                | "excluded-external-cache"
        ) {
            return Err(format!("Unclassified service {name}"));
        }
        let compact = match fields[3] {
            "true" => true,
            "false" => false,
            _ => return Err(format!("Invalid compaction capability for {name}")),
        };
        if compact && role != "cleanup-participant" {
            return Err(format!("Invalid compaction capability for {name}"));
        }
        services.push(Service {
            name: name.to_owned(),
            port,
            role: role.to_owned(),
            compact,
        });
    }
    let authorities = services
        .iter()
        .filter(|service| service.role == "authoritative-read-only")
        .count();
    if authorities != 1
        || !services
            .iter()
            .any(|service| service.role == "cleanup-participant")
    {
        return Err(
            "Backup inventory must contain one authority and at least one participant".to_owned(),
        );
    }
    Ok(services)
}

fn validate_ids(value: Value, service: &str) -> Result<Vec<String>, String> {
    let mut ids = serde_json::from_value::<RecipeIds>(value)
        .map_err(|_| format!("{service} returned an invalid recipe ID inventory"))?
        .recipe_ids;
    if ids.iter().any(String::is_empty) {
        return Err(format!("{service} returned an empty recipe ID"));
    }
    let unique = ids.iter().collect::<BTreeSet<_>>();
    if unique.len() != ids.len() {
        return Err(format!("{service} returned duplicate recipe IDs"));
    }
    let mut sorted = ids.clone();
    sorted.sort();
    if sorted != ids {
        return Err(format!("{service} returned unordered recipe IDs"));
    }
    ids.shrink_to_fit();
    Ok(ids)
}

fn base_url(service: &Service) -> String {
    format!("http://{}:{}", service.name, service.port)
}

async fn get_json(
    client: &reqwest::Client,
    service: &Service,
    path: &str,
) -> Result<(Value, u8), RemoteFailure> {
    let url = format!("{}{path}", base_url(service));
    for attempt in 1..=ATTEMPTS {
        match client.get(&url).send().await {
            Ok(response) if response.status().is_success() => {
                let value = response.json().await.map_err(|error| RemoteFailure {
                    attempts: attempt,
                    detail: format!("Invalid response from {}: {error}", service.name),
                })?;
                return Ok((value, attempt));
            }
            Ok(response) if response.status().is_client_error() => {
                return Err(RemoteFailure {
                    attempts: attempt,
                    detail: format!("{} returned HTTP {}", service.name, response.status()),
                });
            }
            Ok(response) => {
                let detail = format!("{} returned HTTP {}", service.name, response.status());
                if attempt == ATTEMPTS {
                    return Err(RemoteFailure {
                        attempts: attempt,
                        detail,
                    });
                }
            }
            Err(error) if attempt == ATTEMPTS => {
                return Err(RemoteFailure {
                    attempts: attempt,
                    detail: format!("{} request failed: {error}", service.name),
                });
            }
            Err(_) => {}
        }
        tokio::time::sleep(Duration::from_millis(100 * u64::from(attempt))).await;
    }
    unreachable!()
}

async fn post_empty(
    client: &reqwest::Client,
    service: &Service,
    path: &str,
    recipe_id: &str,
) -> Result<u8, RemoteFailure> {
    let url = format!("{}{path}", base_url(service));
    for attempt in 1..=ATTEMPTS {
        match client
            .post(&url)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .json(&serde_json::json!({"recipeId": recipe_id}))
            .send()
            .await
        {
            Ok(response) if response.status().as_u16() == 204 => return Ok(attempt),
            Ok(response) if response.status().is_client_error() => {
                return Err(RemoteFailure {
                    attempts: attempt,
                    detail: format!("{} returned HTTP {}", service.name, response.status()),
                });
            }
            Ok(response) => {
                let detail = format!("{} returned HTTP {}", service.name, response.status());
                if attempt == ATTEMPTS {
                    return Err(RemoteFailure {
                        attempts: attempt,
                        detail,
                    });
                }
            }
            Err(error) if attempt == ATTEMPTS => {
                return Err(RemoteFailure {
                    attempts: attempt,
                    detail: format!("{} request failed: {error}", service.name),
                });
            }
            Err(_) => {}
        }
        tokio::time::sleep(Duration::from_millis(100 * u64::from(attempt))).await;
    }
    unreachable!()
}

fn record_operation(
    summary: &mut Summary,
    service: &str,
    operation: &str,
    ids: Vec<String>,
    attempts: u8,
) {
    summary.operations.push(Operation {
        service: service.to_owned(),
        operation: operation.to_owned(),
        count: ids.len(),
        recipe_ids: ids,
        attempts,
        unresolved_failures: Vec::new(),
    });
}

fn finish(summary: &Summary) {
    println!(
        "{}",
        serde_json::to_string(summary).unwrap_or_else(|_| {
            r#"{"unresolved_failures":["Could not serialize cleanup summary"]}"#.to_owned()
        })
    );
}

pub async fn run() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let target = required_env("BACKUP_TARGET")?;
    let namespace = required_env("BACKUP_NAMESPACE")?;
    validate_target_namespace(&target, &namespace)?;
    let release = required_env("BACKUP_RELEASE")?;
    let revision = required_env("BACKUP_REVISION")?;
    if !valid_release(&release) || !valid_hex(&revision, &[40, 64]) {
        return Err("Invalid release metadata".into());
    }
    let participant_data = required_env("BACKUP_PARTICIPANTS")?;
    let services = parse_services(&participant_data)?;
    let required = services
        .iter()
        .filter(|service| {
            matches!(
                service.role.as_str(),
                "authoritative-read-only" | "cleanup-participant"
            )
        })
        .cloned()
        .collect::<Vec<_>>();
    let authority = required
        .iter()
        .find(|service| service.role == "authoritative-read-only")
        .expect("validated authority");
    let mut summary = Summary {
        target,
        namespace,
        release,
        revision,
        ..Summary::default()
    };
    let client = reqwest::Client::builder()
        .connect_timeout(REQUEST_TIMEOUT)
        .timeout(REQUEST_TIMEOUT)
        .build()?;
    let mut inventories = BTreeMap::<String, Vec<String>>::new();

    for service in &required {
        let status = get_json(&client, service, "/maintenance/status").await;
        let (status, attempts) = match status {
            Ok(result) => result,
            Err(error) => {
                let detail = format!("{} status check failed: {}", service.name, error.detail);
                summary.unresolved_failures.push(detail.clone());
                summary.operations.push(Operation {
                    service: service.name.clone(),
                    operation: "status".to_owned(),
                    recipe_ids: Vec::new(),
                    count: 0,
                    attempts: error.attempts,
                    unresolved_failures: vec![detail.clone()],
                });
                finish(&summary);
                return Err(detail.into());
            }
        };
        if status["version"] != 1 || status["mode"] != "backup" || status["service"] != service.name
        {
            let detail = format!("{} reported unsupported backup status", service.name);
            summary.unresolved_failures.push(detail.clone());
            finish(&summary);
            return Err(detail.into());
        }
        record_operation(&mut summary, &service.name, "status", Vec::new(), attempts);

        let ids = get_json(&client, service, "/maintenance/recipe-ids").await;
        let (ids, attempts) = match ids {
            Ok(result) => result,
            Err(error) => {
                let detail = format!("{} enumeration failed: {}", service.name, error.detail);
                summary.unresolved_failures.push(detail.clone());
                summary.operations.push(Operation {
                    service: service.name.clone(),
                    operation: "enumerate".to_owned(),
                    recipe_ids: Vec::new(),
                    count: 0,
                    attempts: error.attempts,
                    unresolved_failures: vec![detail.clone()],
                });
                finish(&summary);
                return Err(detail.into());
            }
        };
        let ids = match validate_ids(ids, &service.name) {
            Ok(ids) => ids,
            Err(detail) => {
                summary.unresolved_failures.push(detail.clone());
                finish(&summary);
                return Err(detail.into());
            }
        };
        record_operation(
            &mut summary,
            &service.name,
            "enumerate",
            ids.clone(),
            attempts,
        );
        inventories.insert(service.name.clone(), ids);
    }

    let authoritative = inventories
        .get(&authority.name)
        .expect("authority inventory collected")
        .iter()
        .cloned()
        .collect::<BTreeSet<_>>();
    let mut references = BTreeMap::<String, Vec<String>>::new();
    for service in required
        .iter()
        .filter(|service| service.role == "cleanup-participant")
    {
        let ids = inventories
            .get(&service.name)
            .expect("participant inventory collected");
        let orphans = ids
            .iter()
            .filter(|id| !authoritative.contains(*id))
            .cloned()
            .collect::<Vec<_>>();
        references.insert(service.name.clone(), ids.clone());
        for id in orphans {
            match post_empty(&client, service, "/maintenance/recipes/purge", &id).await {
                Ok(attempts) => {
                    record_operation(&mut summary, &service.name, "purge", vec![id], attempts)
                }
                Err(error) => {
                    let detail = format!(
                        "{} purge failed after {} attempt(s): {}",
                        service.name, error.attempts, error.detail
                    );
                    summary.unresolved_failures.push(detail.clone());
                    summary.operations.push(Operation {
                        service: service.name.clone(),
                        operation: "purge".to_owned(),
                        recipe_ids: vec![id],
                        count: 1,
                        attempts: error.attempts,
                        unresolved_failures: vec![detail.clone()],
                    });
                    finish(&summary);
                    return Err(detail.into());
                }
            }
        }
    }

    for service in required.iter().filter(|service| service.compact) {
        let ids = references
            .get(&service.name)
            .expect("compaction service is a participant");
        for id in ids.iter().filter(|id| authoritative.contains(*id)) {
            match post_empty(&client, service, "/maintenance/images/compact", id).await {
                Ok(attempts) => record_operation(
                    &mut summary,
                    &service.name,
                    "compact",
                    vec![id.clone()],
                    attempts,
                ),
                Err(error) => {
                    let detail = format!(
                        "{} compaction failed after {} attempt(s): {}",
                        service.name, error.attempts, error.detail
                    );
                    summary.unresolved_failures.push(detail.clone());
                    summary.operations.push(Operation {
                        service: service.name.clone(),
                        operation: "compact".to_owned(),
                        recipe_ids: vec![id.clone()],
                        count: 1,
                        attempts: error.attempts,
                        unresolved_failures: vec![detail.clone()],
                    });
                    finish(&summary);
                    return Err(detail.into());
                }
            }
        }
    }

    for service in required
        .iter()
        .filter(|service| service.role == "cleanup-participant")
    {
        let result = get_json(&client, service, "/maintenance/recipe-ids").await;
        let (result, attempts) = match result {
            Ok(result) => result,
            Err(error) => {
                let detail = format!("{} verification failed: {}", service.name, error.detail);
                summary.unresolved_failures.push(detail.clone());
                summary.operations.push(Operation {
                    service: service.name.clone(),
                    operation: "verify".to_owned(),
                    recipe_ids: Vec::new(),
                    count: 0,
                    attempts: error.attempts,
                    unresolved_failures: vec![detail.clone()],
                });
                finish(&summary);
                return Err(detail.into());
            }
        };
        let ids = match validate_ids(result, &service.name) {
            Ok(ids) => ids,
            Err(detail) => {
                summary.unresolved_failures.push(detail.clone());
                finish(&summary);
                return Err(detail.into());
            }
        };
        let orphans = ids
            .iter()
            .filter(|id| !authoritative.contains(*id))
            .cloned()
            .collect::<Vec<_>>();
        if !orphans.is_empty() {
            let detail = format!("{} still reports orphaned recipe references", service.name);
            summary.unresolved_failures.push(detail.clone());
            summary.operations.push(Operation {
                service: service.name.clone(),
                operation: "verify".to_owned(),
                count: orphans.len(),
                recipe_ids: orphans,
                attempts,
                unresolved_failures: vec![detail.clone()],
            });
            finish(&summary);
            return Err(detail.into());
        }
        record_operation(&mut summary, &service.name, "verify", ids, attempts);
    }

    finish(&summary);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    async fn mock_service(
        responses: Vec<(u16, &'static str)>,
    ) -> (Service, tokio::task::JoinHandle<usize>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let mut requests = 0;
            for (status, body) in responses {
                let (mut stream, _) = listener.accept().await.unwrap();
                let mut request = [0; 4096];
                let _ = stream.read(&mut request).await.unwrap();
                requests += 1;
                let reason = if status == 204 {
                    "No Content"
                } else if status == 200 {
                    "OK"
                } else {
                    "Service Unavailable"
                };
                let response = format!(
                    "HTTP/1.1 {status} {reason}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                stream.write_all(response.as_bytes()).await.unwrap();
            }
            requests
        });
        (
            Service {
                name: "127.0.0.1".to_owned(),
                port,
                role: "cleanup-participant".to_owned(),
                compact: false,
            },
            server,
        )
    }

    #[test]
    fn participant_metadata_requires_one_authority_and_a_cleanup_participant() {
        let valid =
            "recipes|5000|authoritative-read-only|false,images|8000|cleanup-participant|true";
        assert_eq!(parse_services(valid).unwrap().len(), 2);
        assert!(parse_services("recipes|5000|authoritative-read-only|false").is_err());
        assert!(parse_services("recipes|5000|unknown|false").is_err());
        assert!(parse_services(
            "recipes|5000|authoritative-read-only|false,recipes|5001|cleanup-participant|false"
        )
        .is_err());
    }

    #[test]
    fn target_and_namespace_are_validated_before_remote_operations() {
        assert!(validate_target_namespace("local", "recipe-db").is_ok());
        assert!(validate_target_namespace("pi", "recipe-db").is_ok());
        assert!(validate_target_namespace("unknown", "recipe-db").is_err());
        assert!(validate_target_namespace("local", "Recipe_DB").is_err());
        assert!(validate_target_namespace("local", "-invalid").is_err());
    }

    #[test]
    fn release_must_be_an_immutable_repository_artifact() {
        assert!(valid_release(
            "ghcr.io/dhhyi/recipe-db-releases@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        ));
        assert!(!valid_release("ghcr.io/dhhyi/recipe-db-releases:latest"));
        assert!(!valid_release(
            "example.invalid/releases@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        ));
    }

    #[test]
    fn recipe_id_inventory_must_be_complete_unique_and_ordered() {
        assert_eq!(
            validate_ids(serde_json::json!({"recipeIds":["a","b"]}), "images").unwrap(),
            ["a", "b"]
        );
        assert!(validate_ids(serde_json::json!({"recipeIds":["b","a"]}), "images").is_err());
        assert!(validate_ids(serde_json::json!({"recipeIds":["a","a"]}), "images").is_err());
    }

    #[tokio::test]
    async fn transient_get_failure_retries_and_reports_the_successful_attempt() {
        let (service, server) = mock_service(vec![(503, ""), (200, r#"{"recipeIds":[]}"#)]).await;
        let client = reqwest::Client::builder().build().unwrap();
        let (body, attempts) = get_json(&client, &service, "/maintenance/recipe-ids")
            .await
            .unwrap();
        assert_eq!(body["recipeIds"], serde_json::json!([]));
        assert_eq!(attempts, 2);
        assert_eq!(server.await.unwrap(), 2);
    }

    #[tokio::test]
    async fn retryable_purge_failure_gets_exactly_three_total_attempts() {
        let (service, server) = mock_service(vec![(503, ""), (503, ""), (503, "")]).await;
        let client = reqwest::Client::builder().build().unwrap();
        let failure = post_empty(&client, &service, "/maintenance/recipes/purge", "opaque/id")
            .await
            .unwrap_err();
        assert_eq!(failure.attempts, ATTEMPTS);
        assert_eq!(server.await.unwrap(), 3);
    }

    #[tokio::test]
    async fn purge_retries_are_idempotent_and_stop_on_success() {
        let (service, server) = mock_service(vec![(503, ""), (204, "")]).await;
        let client = reqwest::Client::builder().build().unwrap();
        assert_eq!(
            post_empty(&client, &service, "/maintenance/recipes/purge", "opaque/id")
                .await
                .unwrap(),
            2
        );
        assert_eq!(server.await.unwrap(), 2);
    }
}
