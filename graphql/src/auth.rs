use std::collections::{HashMap, HashSet};
use std::fmt;
use std::fs;
use std::marker::PhantomData;
use std::path::Path;

use async_graphql::{Error, ErrorExtensions};
use axum::http::{HeaderMap, HeaderValue};
use serde::de::{value::MapAccessDeserializer, MapAccess, Visitor};
use serde::{Deserialize, Deserializer};
use serde_json::Value;
use subtle::ConstantTimeEq;

pub const ACCOUNTS_FILE: &str = "/run/secrets/auth-accounts.json";
const SUBJECT_HEADER: &str = "x-auth-request-user";
const ISSUER_HEADER: &str = "x-auth-request-issuer";
const EMAIL_HEADER: &str = "x-auth-request-email";
const EMAIL_VERIFIED_HEADER: &str = "x-auth-request-email-verified";
const AUTHORIZATION_HEADER: &str = "authorization";
const ANONYMOUS_ID: &str = "credential-free:v1";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Role {
    Anonymous,
    Member,
    Owner,
}

impl Role {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "anonymous" => Some(Self::Anonymous),
            "member" => Some(Self::Member),
            "owner" => Some(Self::Owner),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct AccountIdentity {
    issuer: String,
    subject: String,
}

impl AccountIdentity {
    pub fn new(issuer: String, subject: String) -> Result<Self, &'static str> {
        if issuer.is_empty() || issuer.chars().any(char::is_control) {
            return Err("invalid issuer");
        }
        if subject.is_empty() || subject.trim().is_empty() || subject.chars().any(char::is_control)
        {
            return Err("invalid subject");
        }
        Ok(Self { issuer, subject })
    }

    pub fn issuer(&self) -> &str {
        &self.issuer
    }

    pub fn subject(&self) -> &str {
        &self.subject
    }

    pub fn stable_id(&self) -> StablePrincipalId {
        StablePrincipalId(format!(
            "google:v1:{}:{}{}",
            self.issuer.len(),
            self.issuer,
            self.subject
        ))
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct StablePrincipalId(String);

impl StablePrincipalId {
    fn token(id: &str) -> Self {
        Self(format!("token:v1:{}:{id}", id.len()))
    }

    fn credential_free() -> Self {
        Self(ANONYMOUS_ID.to_owned())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PrincipalSource {
    CredentialFree,
    Google,
    Token,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Principal {
    id: StablePrincipalId,
    role: Role,
    display_name: Option<String>,
    source: PrincipalSource,
}

impl Principal {
    pub fn id(&self) -> &StablePrincipalId {
        &self.id
    }

    pub fn role(&self) -> Role {
        self.role
    }

    pub fn display_name(&self) -> Option<&str> {
        self.display_name.as_deref()
    }

    pub fn source(&self) -> PrincipalSource {
        self.source
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Capability {
    ReadPublic,
    ReadAggregateRatings,
    ReadComments,
    WriteComments,
    ReadIndividualRatings,
    WriteRatings,
    ManageRecipes,
    ManageImports,
    ManageImages,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RequestContext {
    principal: Principal,
}

impl RequestContext {
    pub fn principal(&self) -> &Principal {
        &self.principal
    }

    pub fn require(&self, capability: Capability) -> Result<(), AuthorizationError> {
        let role = self.principal.role;
        let allowed = match role {
            Role::Owner => true,
            Role::Member => !matches!(
                capability,
                Capability::ManageRecipes | Capability::ManageImports | Capability::ManageImages
            ),
            Role::Anonymous => matches!(
                capability,
                Capability::ReadPublic | Capability::ReadAggregateRatings
            ),
        };

        if allowed {
            Ok(())
        } else if self.principal.source == PrincipalSource::CredentialFree
            && role == Role::Anonymous
        {
            Err(AuthorizationError::authentication_required())
        } else {
            Err(AuthorizationError::forbidden())
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthorizationError {
    pub status: u16,
    pub code: &'static str,
}

impl AuthorizationError {
    fn authentication_required() -> Self {
        Self {
            status: 401,
            code: "authentication-required",
        }
    }

    fn forbidden() -> Self {
        Self {
            status: 403,
            code: "forbidden",
        }
    }

    pub fn into_graphql_error(self) -> Error {
        let title = if self.status == 401 {
            "Authentication required"
        } else {
            "Forbidden"
        };
        Error::new(title).extend_with(|_, extensions| {
            extensions.set("status", self.status);
            extensions.set("code", self.code);
        })
    }
}

#[derive(Clone, Debug)]
struct Token {
    id: String,
    secret: String,
    role: Role,
    display_name: Option<String>,
}

#[derive(Clone, Debug)]
pub struct AuthPolicy {
    trusted_issuer: String,
    anonymous: AnonymousConfig,
    tokens: Vec<Token>,
    google_accounts: HashMap<String, Role>,
}

#[derive(Clone, Debug)]
struct AnonymousConfig {
    role: Role,
    display_name: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct RawConfig {
    #[serde(rename = "$schema", default)]
    schema: String,
    anonymous: MapOnly<RawAnonymous>,
    tokens: Vec<MapOnly<RawToken>>,
    google_accounts: RawGoogleAccounts,
}

struct MapOnly<T>(T);

impl<'de, T> Deserialize<'de> for MapOnly<T>
where
    T: Deserialize<'de>,
{
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct MapOnlyVisitor<T>(PhantomData<T>);

        impl<'de, T> Visitor<'de> for MapOnlyVisitor<T>
        where
            T: Deserialize<'de>,
        {
            type Value = MapOnly<T>;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("an object")
            }

            fn visit_map<M>(self, map: M) -> Result<Self::Value, M::Error>
            where
                M: MapAccess<'de>,
            {
                T::deserialize(MapAccessDeserializer::new(map)).map(MapOnly)
            }
        }

        deserializer.deserialize_map(MapOnlyVisitor(PhantomData))
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct RawAnonymous {
    role: String,
    #[serde(default, deserialize_with = "deserialize_display_name")]
    display_name: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct RawToken {
    id: String,
    secret: String,
    role: String,
    #[serde(default, deserialize_with = "deserialize_display_name")]
    display_name: Option<String>,
}

fn deserialize_display_name<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    String::deserialize(deserializer).map(Some)
}

struct RawGoogleAccounts(Vec<(String, Value)>);

impl<'de> Deserialize<'de> for RawGoogleAccounts {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct GoogleAccountsVisitor;

        impl<'de> Visitor<'de> for GoogleAccountsVisitor {
            type Value = RawGoogleAccounts;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("an object mapping email addresses to roles")
            }

            fn visit_map<M>(self, mut map: M) -> Result<Self::Value, M::Error>
            where
                M: MapAccess<'de>,
            {
                let mut seen = HashSet::new();
                let mut entries = Vec::new();
                while let Some(email) = map.next_key::<String>()? {
                    if !seen.insert(email.clone()) {
                        return Err(serde::de::Error::custom("duplicate Google email key"));
                    }
                    entries.push((email, map.next_value::<Value>()?));
                }
                Ok(RawGoogleAccounts(entries))
            }
        }

        deserializer.deserialize_map(GoogleAccountsVisitor)
    }
}

impl AuthPolicy {
    pub fn load() -> Result<Self, String> {
        let issuer = std::env::var("AUTH_TRUSTED_ISSUER")
            .map_err(|_| "AUTH_TRUSTED_ISSUER is required".to_owned())?;
        Self::load_from(Path::new(ACCOUNTS_FILE), &issuer)
    }

    fn load_from(path: &Path, trusted_issuer: &str) -> Result<Self, String> {
        let contents = fs::read_to_string(path).map_err(|_| {
            format!(
                "could not read authorization configuration at {}",
                path.display()
            )
        })?;
        Self::from_json(&contents, trusted_issuer)
    }

    pub fn from_json(json: &str, trusted_issuer: &str) -> Result<Self, String> {
        if trusted_issuer.is_empty()
            || trusted_issuer.trim() != trusted_issuer
            || trusted_issuer == "*"
            || trusted_issuer.chars().any(char::is_control)
        {
            return Err("trusted issuer must be explicit and nonempty".to_owned());
        }
        let raw = serde_json::from_str::<RawConfig>(json).map_err(|_| {
            "authorization configuration is malformed or contains duplicate keys".to_owned()
        })?;
        let _ = raw.schema;
        let anonymous = AnonymousConfig {
            role: parse_role(&raw.anonymous.0.role)?,
            display_name: raw.anonymous.0.display_name,
        };

        let mut token_ids = HashSet::new();
        let mut token_secrets = HashSet::new();
        let mut tokens = Vec::with_capacity(raw.tokens.len());
        for token in raw.tokens.into_iter().map(|token| token.0) {
            if token.id.is_empty() || token.secret.is_empty() {
                return Err("token IDs and secrets must be nonempty".to_owned());
            }
            let unpadded_secret = token.secret.trim_end_matches('=');
            if unpadded_secret.is_empty()
                || !unpadded_secret
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"-._~+/".contains(&byte))
            {
                return Err("token secrets must match RFC 6750 b64token syntax".to_owned());
            }
            if !token_ids.insert(token.id.clone()) {
                return Err("authorization configuration contains duplicate token IDs".to_owned());
            }
            if !token_secrets.insert(token.secret.clone()) {
                return Err(
                    "authorization configuration contains duplicate token secrets".to_owned(),
                );
            }
            tokens.push(Token {
                id: token.id,
                secret: token.secret,
                role: parse_role(&token.role)?,
                display_name: token.display_name,
            });
        }

        let mut google_accounts = HashMap::new();
        for (email, role) in raw.google_accounts.0 {
            let email = normalize_email(&email).ok_or_else(|| {
                "authorization configuration contains an invalid Google email".to_owned()
            })?;
            let role = role.as_str().ok_or_else(|| {
                "authorization configuration Google roles must be strings".to_owned()
            })?;
            let role = parse_role(role)?;
            if google_accounts.insert(email, role).is_some() {
                return Err(
                    "authorization configuration contains colliding normalized emails".to_owned(),
                );
            }
        }

        Ok(Self {
            trusted_issuer: trusted_issuer.to_owned(),
            anonymous,
            tokens,
            google_accounts,
        })
    }

    pub fn request_context(&self, headers: &HeaderMap) -> Result<RequestContext, AuthContextError> {
        let authorization = single_header(headers, AUTHORIZATION_HEADER)?;
        let google_headers = google_context_headers(headers)?;
        if let Some(authorization) = authorization {
            if google_headers.any_present() {
                return Err(AuthContextError::mixed_credentials());
            }
            let secret = bearer_secret(authorization)?;
            let mut matched_index = 0_usize;
            let mut match_count = 0_u8;
            for (index, token) in self.tokens.iter().enumerate() {
                let equal = secret.as_bytes().ct_eq(token.secret.as_bytes()).unwrap_u8();
                match_count = match_count.saturating_add(equal);
                let mask = 0_usize.wrapping_sub(usize::from(equal));
                matched_index = (matched_index & !mask) | (index & mask);
            }
            if match_count != 1 {
                return Err(AuthContextError::invalid_credentials());
            }
            let token = &self.tokens[matched_index];
            return Ok(RequestContext {
                principal: Principal {
                    id: StablePrincipalId::token(&token.id),
                    role: token.role,
                    display_name: token.display_name.clone(),
                    source: PrincipalSource::Token,
                },
            });
        }

        if !google_headers.any_present() {
            return Ok(RequestContext {
                principal: Principal {
                    id: StablePrincipalId::credential_free(),
                    role: self.anonymous.role,
                    display_name: self.anonymous.display_name.clone(),
                    source: PrincipalSource::CredentialFree,
                },
            });
        }

        let (identity, email, email_verified) = google_headers.validate(&self.trusted_issuer)?;
        let role = if email_verified {
            self.google_accounts
                .get(&normalize_email(email).ok_or_else(AuthContextError::invalid)?)
                .copied()
                .unwrap_or(Role::Anonymous)
        } else {
            Role::Anonymous
        };
        Ok(RequestContext {
            principal: Principal {
                id: identity.stable_id(),
                role,
                display_name: None,
                source: PrincipalSource::Google,
            },
        })
    }
}

fn parse_role(value: &str) -> Result<Role, String> {
    Role::parse(value)
        .ok_or_else(|| "authorization configuration contains an unknown role".to_owned())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AuthContextError {
    status: u16,
    code: &'static str,
}

impl AuthContextError {
    fn invalid() -> Self {
        Self {
            status: 400,
            code: "invalid-auth-context",
        }
    }

    fn invalid_credentials() -> Self {
        Self {
            status: 401,
            code: "invalid-credentials",
        }
    }

    fn mixed_credentials() -> Self {
        Self {
            status: 400,
            code: "mixed-auth-context",
        }
    }

    pub fn into_graphql_error(self) -> Error {
        let title = if self.status == 401 {
            "Invalid credentials"
        } else {
            "Invalid authentication context"
        };
        Error::new(title).extend_with(|_, extensions| {
            extensions.set("status", self.status);
            extensions.set("code", self.code);
        })
    }
}

fn single_header<'a>(
    headers: &'a HeaderMap,
    name: &'static str,
) -> Result<Option<&'a HeaderValue>, AuthContextError> {
    let mut values = headers.get_all(name).iter();
    let first = values.next();
    if values.next().is_some() {
        return Err(if name == AUTHORIZATION_HEADER {
            AuthContextError::invalid_credentials()
        } else {
            AuthContextError::invalid()
        });
    }
    Ok(first)
}

fn bearer_secret(header: &HeaderValue) -> Result<&str, AuthContextError> {
    let value = header
        .to_str()
        .map_err(|_| AuthContextError::invalid_credentials())?;
    let (scheme, secret) = value
        .split_once(' ')
        .ok_or_else(AuthContextError::invalid_credentials)?;
    let secret = secret.trim_start_matches(' ');
    if !scheme.eq_ignore_ascii_case("Bearer")
        || secret.is_empty()
        || secret.contains(',')
        || secret.chars().any(char::is_control)
    {
        return Err(AuthContextError::invalid_credentials());
    }
    Ok(secret)
}

struct GoogleHeaders<'a> {
    subject: Option<&'a HeaderValue>,
    issuer: Option<&'a HeaderValue>,
    email: Option<&'a HeaderValue>,
    verified: Option<&'a HeaderValue>,
}

impl GoogleHeaders<'_> {
    fn any_present(&self) -> bool {
        self.subject.is_some()
            || self.issuer.is_some()
            || self.email.is_some()
            || self.verified.is_some()
    }

    fn validate<'a>(
        &'a self,
        trusted_issuer: &str,
    ) -> Result<(AccountIdentity, &'a str, bool), AuthContextError> {
        let subject = required_header(self.subject)?;
        let issuer = required_header(self.issuer)?;
        let email = required_header(self.email)?;
        if issuer != trusted_issuer || normalize_email(email).is_none() {
            return Err(AuthContextError::invalid());
        }
        let verified = self
            .verified
            .map(|value| {
                let value = value.to_str().map_err(|_| AuthContextError::invalid())?;
                Ok::<_, AuthContextError>(value == "true")
            })
            .transpose()?
            .unwrap_or(false);
        let identity = AccountIdentity::new(issuer.to_owned(), subject.to_owned())
            .map_err(|_| AuthContextError::invalid())?;
        Ok((identity, email, verified))
    }
}

fn google_context_headers(headers: &HeaderMap) -> Result<GoogleHeaders<'_>, AuthContextError> {
    Ok(GoogleHeaders {
        subject: single_header(headers, SUBJECT_HEADER)?,
        issuer: single_header(headers, ISSUER_HEADER)?,
        email: single_header(headers, EMAIL_HEADER)?,
        verified: single_header(headers, EMAIL_VERIFIED_HEADER)?,
    })
}

fn required_header(value: Option<&HeaderValue>) -> Result<&str, AuthContextError> {
    let value = value
        .ok_or_else(AuthContextError::invalid)?
        .to_str()
        .map_err(|_| AuthContextError::invalid())?;
    if value.is_empty() {
        Err(AuthContextError::invalid())
    } else {
        Ok(value)
    }
}

fn normalize_email(email: &str) -> Option<String> {
    if email.trim() != email || !email.is_ascii() || email.chars().any(char::is_control) {
        return None;
    }
    let (local, domain) = email.split_once('@')?;
    if local.is_empty()
        || domain.is_empty()
        || domain.contains('@')
        || local.len() > 64
        || email.len() > 254
        || local.starts_with('.')
        || local.ends_with('.')
        || local.contains("..")
        || !local
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b".!#$%&'*+/=?^_`{|}~-".contains(&byte))
    {
        return None;
    }
    let labels = domain.split('.').collect::<Vec<_>>();
    if labels.len() < 2
        || labels.iter().any(|label| {
            label.is_empty()
                || label.len() > 63
                || label.starts_with('-')
                || label.ends_with('-')
                || !label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
    {
        return None;
    }
    Some(email.to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::{HeaderName, HeaderValue};

    const ISSUER: &str = "https://accounts.example.test";
    const FULL_CONFIG: &str = r#"{
      "anonymous":{"role":"anonymous","displayName":"Guest"},
      "tokens":[
        {"id":"member-token","secret":"secret-one","role":"member","displayName":"E2E"},
        {"id":"owner-token","secret":"secret-two","role":"owner"}
      ],
      "googleAccounts":{
        "owner@example.com":"owner",
        "member@example.com":"member",
        "alias+tag@example.com":"member"
      }
    }"#;

    fn policy(json: &str) -> AuthPolicy {
        AuthPolicy::from_json(json, ISSUER).unwrap()
    }

    fn headers(entries: &[(&str, &str)]) -> HeaderMap {
        let mut headers = HeaderMap::new();
        for (name, value) in entries {
            headers.append(
                HeaderName::from_bytes(name.as_bytes()).unwrap(),
                HeaderValue::from_str(value).unwrap(),
            );
        }
        headers
    }

    fn google_headers(email: &str, verified: Option<&str>) -> HeaderMap {
        let mut entries = vec![
            (SUBJECT_HEADER, "subject-1"),
            (ISSUER_HEADER, ISSUER),
            (EMAIL_HEADER, email),
        ];
        if let Some(verified) = verified {
            entries.push((EMAIL_VERIFIED_HEADER, verified));
        }
        headers(&entries)
    }

    fn bearer(secret: &str) -> HeaderMap {
        let mut authorization = String::from("Be");
        authorization.push_str("arer ");
        authorization.push_str(secret);
        headers(&[(AUTHORIZATION_HEADER, &authorization)])
    }

    #[test]
    fn parses_read_only_token_only_and_privileged_anonymous_configurations() {
        let schema_annotated = policy(
            r#"{"$schema":"../graphql/auth-accounts.schema.json","anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{}}"#,
        );
        assert_eq!(schema_annotated.tokens.len(), 0);
        let token_only = policy(
            r#"{"anonymous":{"role":"anonymous"},"tokens":[{"id":"one","secret":"s","role":"owner"}],"googleAccounts":{}}"#,
        );
        assert_eq!(token_only.tokens.len(), 1);
        let no_tokens = policy(
            r#"{"anonymous":{"role":"owner","displayName":"Shared"},"tokens":[],"googleAccounts":{}}"#,
        );
        let principal = no_tokens
            .request_context(&HeaderMap::new())
            .unwrap()
            .principal()
            .clone();
        assert_eq!(principal.role(), Role::Owner);
        assert_eq!(principal.display_name(), Some("Shared"));
        assert!(principal.id().as_str().starts_with("credential-free:"));
    }

    #[test]
    fn fresh_startup_load_honors_privileged_credential_free_roles_without_fallback() {
        for role in ["member", "owner"] {
            let path = std::env::temp_dir().join(format!("auth-config-{}", uuid::Uuid::new_v4()));
            let json = format!(
                r#"{{"anonymous":{{"role":"{role}"}},"tokens":[{{"id":"owner","secret":"known-token","role":"owner"}}],"googleAccounts":{{}}}}"#
            );
            fs::write(&path, json).unwrap();
            let policy = AuthPolicy::load_from(&path, ISSUER).unwrap();
            let _ = fs::remove_file(&path);

            assert_eq!(
                policy
                    .request_context(&HeaderMap::new())
                    .unwrap()
                    .principal()
                    .role(),
                Role::parse(role).unwrap()
            );
            assert_eq!(
                policy
                    .request_context(&bearer("invalid-token"))
                    .unwrap_err()
                    .code,
                "invalid-credentials"
            );
        }
    }

    #[test]
    fn strict_configuration_rejects_invalid_shapes_keys_and_values() {
        let invalid = [
            "{",
            "[]",
            r#"{"anonymous":{"role":"nope"},"tokens":[],"googleAccounts":{}}"#,
            r#"{"anonymous":{"role":"anonymous","extra":true},"tokens":[],"googleAccounts":{}}"#,
            r#"{"anonymous":{"role":"anonymous","displayName":null},"tokens":[],"googleAccounts":{}}"#,
            r#"{"anonymous":{"role":"anonymous"},"tokens":[{"id":"x","secret":"s","role":"member","extra":true}],"googleAccounts":{}}"#,
            r#"{"anonymous":{"role":"anonymous"},"tokens":[{"id":"x","secret":"s","role":"member","displayName":null}],"googleAccounts":{}}"#,
            r#"{"anonymous":{"role":"anonymous"},"tokens":[{"id":"x","id":"y","secret":"s","role":"member"}],"googleAccounts":{}}"#,
            r#"{"anonymous":["anonymous","Guest"],"tokens":[],"googleAccounts":{}}"#,
            r#"{"anonymous":{"role":"anonymous"},"tokens":[["x","s","member","Name"]],"googleAccounts":{}}"#,
            r#"{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":[["owner@example.com","owner"]]}"#,
            r#"{"anonymous":{"role":"anonymous"},"tokens":[{"id":"","secret":"s","role":"member"}],"googleAccounts":{}}"#,
            r#"{"anonymous":{"role":"anonymous"},"tokens":[{"id":"x","secret":"","role":"member"}],"googleAccounts":{}}"#,
            r#"{"anonymous":{"role":"anonymous"},"tokens":[{"id":"x","secret":"s","role":"bad"}],"googleAccounts":{}}"#,
            r#"{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{"bad..dot@example.com":"member"}}"#,
            r#"{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{" owner@example.com":"owner"}}"#,
            r#"{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{"owner@example.com":5}}"#,
            r#"{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{"owner@example.com":"admin"}}"#,
            r#"{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{"owner@example.com":"owner","OWNER@example.com":"member"}}"#,
            r#"{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{"owner@example.com":"owner","owner@example.com":"member"}}"#,
            r#"{"anonymous":{"role":"anonymous"},"tokens":[{"id":"x","secret":"s","role":"member"},{"id":"x","secret":"z","role":"owner"}],"googleAccounts":{}}"#,
            r#"{"anonymous":{"role":"anonymous"},"tokens":[{"id":"x","secret":"s","role":"member"},{"id":"y","secret":"s","role":"owner"}],"googleAccounts":{}}"#,
            r#"{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{},"googleAccounts":{}}"#,
            r#"{"anonymous":{"role":"anonymous","role":"owner"},"tokens":[],"googleAccounts":{}}"#,
            r#"{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{},"unknown":1}"#,
            r#"{"$schema":42,"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{}}"#,
            r#"{"$schema":null,"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{}}"#,
        ];
        for json in invalid {
            let error = AuthPolicy::from_json(json, ISSUER).unwrap_err();
            assert!(!error.contains("secret-one"), "{error}");
            assert!(!error.contains("owner@example.com"), "{error}");
        }
    }

    #[test]
    fn missing_file_fails_with_safe_diagnostic() {
        let root = std::env::temp_dir().join(format!("auth-config-{}", uuid::Uuid::new_v4()));
        let error = AuthPolicy::load_from(&root, ISSUER).unwrap_err();
        assert!(!error.contains("secret"));
    }

    #[test]
    fn resolves_credential_free_google_and_token_principals() {
        let policy = policy(FULL_CONFIG);
        let guest = policy.request_context(&HeaderMap::new()).unwrap();
        assert_eq!(guest.principal().role(), Role::Anonymous);
        assert_eq!(guest.principal().display_name(), Some("Guest"));
        assert_eq!(
            guest.principal().id().as_str(),
            policy
                .request_context(&headers(&[]))
                .unwrap()
                .principal()
                .id()
                .as_str()
        );

        let member = policy.request_context(&bearer("secret-one")).unwrap();
        assert_eq!(member.principal().role(), Role::Member);
        assert_eq!(member.principal().display_name(), Some("E2E"));
        assert_eq!(member.principal().id().as_str(), "token:v1:12:member-token");

        let owner = policy.request_context(&bearer("secret-two")).unwrap();
        assert_eq!(owner.principal().role(), Role::Owner);

        let google = policy
            .request_context(&google_headers("OWNER@example.com", Some("true")))
            .unwrap();
        assert_eq!(google.principal().role(), Role::Owner);
        assert!(google.principal().id().as_str().starts_with("google:v1:"));
        assert_ne!(google.principal().id(), member.principal().id());
        assert_ne!(google.principal().id(), guest.principal().id());
    }

    #[test]
    fn stable_ids_preserve_google_email_changes_and_token_secret_rotation() {
        let auth_policy = policy(FULL_CONFIG);
        let first_email = auth_policy
            .request_context(&google_headers("member@example.com", Some("true")))
            .unwrap();
        let changed_email = auth_policy
            .request_context(&google_headers("owner@example.com", Some("true")))
            .unwrap();
        assert_eq!(first_email.principal().id(), changed_email.principal().id());
        assert_eq!(first_email.principal().role(), Role::Member);
        assert_eq!(changed_email.principal().role(), Role::Owner);
        let different_subject = auth_policy
            .request_context(&headers(&[
                (SUBJECT_HEADER, "subject-2"),
                (ISSUER_HEADER, ISSUER),
                (EMAIL_HEADER, "member@example.com"),
                (EMAIL_VERIFIED_HEADER, "true"),
            ]))
            .unwrap();
        assert_ne!(
            first_email.principal().id(),
            different_subject.principal().id()
        );

        let original = auth_policy.request_context(&bearer("secret-one")).unwrap();
        let rotated = policy(
            r#"{"anonymous":{"role":"anonymous"},"tokens":[{"id":"member-token","secret":"rotated-secret","role":"owner"}],"googleAccounts":{}}"#,
        );
        let after_rotation = rotated.request_context(&bearer("rotated-secret")).unwrap();
        assert_eq!(original.principal().id(), after_rotation.principal().id());
        assert_eq!(after_rotation.principal().role(), Role::Owner);
        assert_ne!(
            after_rotation.principal().id(),
            &StablePrincipalId::token("other-token")
        );
        let removed = AuthPolicy::from_json(
            r#"{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{}}"#,
            ISSUER,
        )
        .unwrap();
        assert_eq!(
            removed
                .request_context(&bearer("secret-one"))
                .unwrap_err()
                .code,
            "invalid-credentials"
        );
    }

    #[test]
    fn fresh_policy_changes_existing_context_permissions_on_the_next_request() {
        let headers = google_headers("member@example.com", Some("true"));
        let member_policy = policy(
            r#"{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{"member@example.com":"owner"}}"#,
        );
        let demoted_policy = policy(
            r#"{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{"member@example.com":"member"}}"#,
        );
        let before_restart = member_policy.request_context(&headers).unwrap();
        let after_restart = demoted_policy.request_context(&headers).unwrap();
        assert_eq!(
            before_restart.principal().id(),
            after_restart.principal().id()
        );
        assert_eq!(before_restart.principal().role(), Role::Owner);
        assert_eq!(after_restart.principal().role(), Role::Member);
    }

    #[test]
    fn stable_identity_namespaces_and_google_components_do_not_collide() {
        let google_a = AccountIdentity::new("issuer:one".to_owned(), "subject".to_owned())
            .unwrap()
            .stable_id();
        let google_b = AccountIdentity::new("issuer".to_owned(), "one:subject".to_owned())
            .unwrap()
            .stable_id();
        let token = StablePrincipalId::token("issuer:one");
        let credential_free = StablePrincipalId::credential_free();
        assert_ne!(google_a, google_b);
        assert_ne!(google_a, token);
        assert_ne!(google_b, token);
        assert_ne!(token, credential_free);
        assert!(!token.as_str().contains("secret"));
    }

    #[test]
    fn unknown_google_identity_never_inherits_privileged_anonymous_role() {
        let policy = policy(r#"{"anonymous":{"role":"owner"},"tokens":[],"googleAccounts":{}}"#);
        let mut headers = google_headers("outsider@example.com", Some("true"));
        headers.insert("x-auth-request-role", HeaderValue::from_static("owner"));
        let unknown = policy.request_context(&headers).unwrap();
        assert_eq!(unknown.principal().role(), Role::Anonymous);
        assert_ne!(unknown.principal().id().as_str(), ANONYMOUS_ID);
    }

    #[test]
    fn unverified_google_identity_is_unprivileged() {
        let auth_policy = policy(FULL_CONFIG);
        for verified in [None, Some("false"), Some("TRUE")] {
            let context = auth_policy
                .request_context(&google_headers("owner@example.com", verified))
                .unwrap();
            assert_eq!(context.principal().role(), Role::Anonymous);
        }
    }

    #[test]
    fn invalid_or_mixed_credentials_never_downgrade_to_anonymous() {
        let policy = policy(
            r#"{"anonymous":{"role":"owner"},"tokens":[{"id":"known","secret":"correct","role":"member"}],"googleAccounts":{"owner@example.com":"owner"}}"#,
        );
        for header in [
            "not-a-bearer",
            "Bearer ",
            "Basic correct",
            concat!("Be", "arer wrong"),
        ] {
            let error = policy
                .request_context(&headers(&[(AUTHORIZATION_HEADER, header)]))
                .unwrap_err();
            assert_eq!(error.code, "invalid-credentials");
        }

        let mut duplicate = bearer("correct");
        duplicate.append(
            AUTHORIZATION_HEADER,
            HeaderValue::from_static(concat!("Be", "arer other")),
        );
        assert_eq!(
            policy.request_context(&duplicate).unwrap_err().code,
            "invalid-credentials"
        );

        let mut mixed = bearer("correct");
        mixed.extend(google_headers("owner@example.com", Some("true")));
        assert_eq!(
            policy.request_context(&mixed).unwrap_err().code,
            "mixed-auth-context"
        );

        assert_eq!(
            policy
                .request_context(&bearer("correct"))
                .unwrap()
                .principal()
                .role(),
            Role::Member
        );
    }

    #[test]
    fn malformed_google_context_is_rejected_without_fallback() {
        let policy = policy(r#"{"anonymous":{"role":"owner"},"tokens":[],"googleAccounts":{}}"#);
        for request_headers in [
            headers(&[(SUBJECT_HEADER, "subject")]),
            headers(&[
                (SUBJECT_HEADER, "subject"),
                (ISSUER_HEADER, "https://wrong.example"),
                (EMAIL_HEADER, "owner@example.com"),
            ]),
            headers(&[
                (SUBJECT_HEADER, ""),
                (ISSUER_HEADER, ISSUER),
                (EMAIL_HEADER, "owner@example.com"),
            ]),
            headers(&[
                (SUBJECT_HEADER, "subject"),
                (ISSUER_HEADER, ISSUER),
                (EMAIL_HEADER, "owner@example.com "),
            ]),
        ] {
            assert_eq!(
                policy.request_context(&request_headers).unwrap_err().code,
                "invalid-auth-context"
            );
        }
        let mut duplicate = google_headers("owner@example.com", Some("true"));
        duplicate.append(SUBJECT_HEADER, HeaderValue::from_static("second"));
        assert_eq!(
            policy.request_context(&duplicate).unwrap_err().code,
            "invalid-auth-context"
        );
    }

    #[test]
    fn capabilities_follow_effective_role_for_all_principal_sources() {
        let auth_policy = policy(FULL_CONFIG);
        let cases = [
            (HeaderMap::new(), Role::Anonymous),
            (bearer("secret-one"), Role::Member),
            (bearer("secret-two"), Role::Owner),
            (
                google_headers("member@example.com", Some("true")),
                Role::Member,
            ),
            (
                google_headers("owner@example.com", Some("true")),
                Role::Owner,
            ),
        ];
        let capabilities = [
            Capability::ReadPublic,
            Capability::ReadAggregateRatings,
            Capability::ReadComments,
            Capability::WriteComments,
            Capability::ReadIndividualRatings,
            Capability::WriteRatings,
            Capability::ManageRecipes,
            Capability::ManageImports,
            Capability::ManageImages,
        ];
        for (headers, role) in cases {
            let context = auth_policy.request_context(&headers).unwrap();
            assert_eq!(context.principal().role(), role);
            for capability in capabilities {
                let expected = match role {
                    Role::Owner => true,
                    Role::Member => !matches!(
                        capability,
                        Capability::ManageRecipes
                            | Capability::ManageImports
                            | Capability::ManageImages
                    ),
                    Role::Anonymous => matches!(
                        capability,
                        Capability::ReadPublic | Capability::ReadAggregateRatings
                    ),
                };
                assert_eq!(context.require(capability).is_ok(), expected);
            }
        }

        let credential_free =
            policy(r#"{"anonymous":{"role":"member"},"tokens":[],"googleAccounts":{}}"#)
                .request_context(&HeaderMap::new())
                .unwrap();
        assert!(credential_free.require(Capability::WriteRatings).is_ok());
        assert!(credential_free.require(Capability::ManageRecipes).is_err());
    }

    #[test]
    fn auth_errors_are_structured_and_unknown_authorization_never_gets_guest_role() {
        let policy = policy(r#"{"anonymous":{"role":"owner"},"tokens":[],"googleAccounts":{}}"#);
        let error = policy
            .request_context(&bearer("wrong"))
            .unwrap_err()
            .into_graphql_error();
        assert_eq!(
            error.extensions.as_ref().unwrap().get("status"),
            Some(&async_graphql::Value::from(401))
        );
        assert_eq!(
            error.extensions.as_ref().unwrap().get("code"),
            Some(&async_graphql::Value::from("invalid-credentials"))
        );
        let forbidden = policy
            .request_context(&google_headers("outsider@example.com", Some("true")))
            .unwrap()
            .require(Capability::ManageRecipes)
            .unwrap_err();
        assert_eq!(forbidden.status, 403);
        assert_eq!(forbidden.code, "forbidden");
    }
}
