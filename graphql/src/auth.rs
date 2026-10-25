use std::collections::{HashMap, HashSet};
use std::fmt;
use std::fs;
use std::path::Path;

use async_graphql::{Error, ErrorExtensions};
use axum::http::HeaderMap;
use serde::de::{MapAccess, Visitor};
use serde::{Deserialize, Deserializer};
use serde_json::Value;

pub const ACCOUNTS_FILE: &str = "/run/secrets/auth-accounts.json";
const SUBJECT_HEADER: &str = "x-auth-request-user";
const ISSUER_HEADER: &str = "x-auth-request-issuer";
const EMAIL_HEADER: &str = "x-auth-request-email";
const EMAIL_VERIFIED_HEADER: &str = "x-auth-request-email-verified";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Role {
    Member,
    Owner,
}

impl Role {
    fn parse(value: &str) -> Option<Self> {
        match value {
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

    #[allow(dead_code)]
    pub fn issuer(&self) -> &str {
        &self.issuer
    }

    #[allow(dead_code)]
    pub fn subject(&self) -> &str {
        &self.subject
    }

    pub fn stable_key(&self) -> String {
        format!("v1:{}:{}{}", self.issuer.len(), self.issuer, self.subject)
    }

    pub fn from_stable_key(key: &str) -> Result<Self, &'static str> {
        let encoded = key.strip_prefix("v1:").ok_or("invalid identity key")?;
        let (length, value) = encoded.split_once(':').ok_or("invalid identity key")?;
        if length.is_empty() || !length.bytes().all(|byte| byte.is_ascii_digit()) {
            return Err("invalid identity key");
        }
        let issuer_length = length
            .parse::<usize>()
            .map_err(|_| "invalid identity key")?;
        if length != issuer_length.to_string() {
            return Err("invalid identity key");
        }
        if issuer_length == 0
            || issuer_length > value.len()
            || !value.is_char_boundary(issuer_length)
        {
            return Err("invalid identity key");
        }
        let (issuer, subject) = value.split_at(issuer_length);
        Self::new(issuer.to_owned(), subject.to_owned())
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
    AdministerAccountPolicy,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Principal {
    Anonymous,
    Authenticated {
        identity: AccountIdentity,
        email: String,
        email_verified: bool,
        role: Option<Role>,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RequestContext {
    principal: Principal,
}

impl RequestContext {
    pub fn anonymous() -> Self {
        Self {
            principal: Principal::Anonymous,
        }
    }

    pub fn principal(&self) -> &Principal {
        &self.principal
    }

    pub fn require(&self, capability: Capability) -> Result<(), AuthorizationError> {
        let role = match &self.principal {
            Principal::Anonymous => {
                if matches!(
                    capability,
                    Capability::ReadPublic | Capability::ReadAggregateRatings
                ) {
                    return Ok(());
                }
                return Err(AuthorizationError::authentication_required());
            }
            Principal::Authenticated { role, .. } => *role,
        };

        let allowed = match role {
            Some(Role::Owner) => true,
            Some(Role::Member) => !matches!(
                capability,
                Capability::ManageRecipes
                    | Capability::ManageImports
                    | Capability::ManageImages
                    | Capability::AdministerAccountPolicy
            ),
            None => matches!(
                capability,
                Capability::ReadPublic | Capability::ReadAggregateRatings
            ),
        };

        if allowed {
            Ok(())
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
pub struct AuthPolicy {
    trusted_issuer: String,
    accounts: HashMap<String, Role>,
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
                "could not read authorization account map at {}",
                path.display()
            )
        })?;
        Self::from_json(&contents, trusted_issuer)
    }

    pub fn from_json(json: &str, trusted_issuer: &str) -> Result<Self, String> {
        if trusted_issuer.is_empty()
            || trusted_issuer.trim() != trusted_issuer
            || trusted_issuer == "*"
        {
            return Err("trusted issuer must be explicit and nonempty".to_owned());
        }

        let raw = serde_json::from_str::<RawAccounts>(json).map_err(|error| {
            if error.to_string().starts_with("duplicate email key") {
                "authorization account map contains duplicate email keys".to_owned()
            } else {
                "authorization account map is malformed JSON".to_owned()
            }
        })?;
        let mut accounts = HashMap::new();
        let mut owners = 0;

        for (email, role) in raw.0 {
            let normalized = normalize_email(&email)
                .ok_or_else(|| "authorization account map contains an invalid email".to_owned())?;
            let role = role
                .as_str()
                .ok_or_else(|| "authorization account map roles must be strings".to_owned())?;
            let role = Role::parse(role)
                .ok_or_else(|| "authorization account map contains an unknown role".to_owned())?;
            if accounts.insert(normalized, role).is_some() {
                return Err(
                    "authorization account map contains colliding normalized emails".to_owned(),
                );
            }
            owners += usize::from(role == Role::Owner);
        }

        if owners == 0 {
            return Err("authorization account map must contain an owner".to_owned());
        }

        Ok(Self {
            trusted_issuer: trusted_issuer.to_owned(),
            accounts,
        })
    }

    pub fn request_context(&self, headers: &HeaderMap) -> Result<RequestContext, AuthContextError> {
        let values = [
            (SUBJECT_HEADER, single_header(headers, SUBJECT_HEADER)?),
            (ISSUER_HEADER, single_header(headers, ISSUER_HEADER)?),
            (EMAIL_HEADER, single_header(headers, EMAIL_HEADER)?),
            (
                EMAIL_VERIFIED_HEADER,
                single_header(headers, EMAIL_VERIFIED_HEADER)?,
            ),
        ];

        if values.iter().all(|(_, value)| value.is_none()) {
            return Ok(RequestContext::anonymous());
        }

        let subject = header_text(values[0].1)?;
        let issuer = header_text(values[1].1)?;
        let email = header_text(values[2].1)?;
        let email_verified = values[3]
            .1
            .map(|value| {
                value
                    .to_str()
                    .map(|value| value == "true")
                    .map_err(|_| AuthContextError::invalid())
            })
            .transpose()?
            .unwrap_or(false);

        if issuer != self.trusted_issuer {
            return Err(AuthContextError::invalid());
        }
        let email = normalize_email(email).ok_or_else(AuthContextError::invalid)?;
        let identity = AccountIdentity::new(issuer.to_owned(), subject.to_owned())
            .map_err(|_| AuthContextError::invalid())?;
        let role = if email_verified {
            self.accounts.get(&email).copied()
        } else {
            None
        };

        Ok(RequestContext {
            principal: Principal::Authenticated {
                identity,
                email,
                email_verified,
                role,
            },
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AuthContextError;

impl AuthContextError {
    fn invalid() -> Self {
        Self
    }

    pub fn into_graphql_error(self) -> Error {
        Error::new("Invalid authentication context").extend_with(|_, extensions| {
            extensions.set("status", 400);
            extensions.set("code", "invalid-auth-context");
        })
    }
}

fn single_header<'a>(
    headers: &'a HeaderMap,
    name: &'static str,
) -> Result<Option<&'a axum::http::HeaderValue>, AuthContextError> {
    let mut values = headers.get_all(name).iter();
    let first = values.next();
    if values.next().is_some() {
        return Err(AuthContextError::invalid());
    }
    Ok(first)
}

fn header_text(value: Option<&axum::http::HeaderValue>) -> Result<&str, AuthContextError> {
    value
        .ok_or_else(AuthContextError::invalid)?
        .to_str()
        .map_err(|_| AuthContextError::invalid())
        .and_then(|text| {
            if text.is_empty() {
                Err(AuthContextError::invalid())
            } else {
                Ok(text)
            }
        })
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
    {
        return None;
    }
    if !local
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

struct RawAccounts(Vec<(String, Value)>);

impl<'de> Deserialize<'de> for RawAccounts {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct AccountsVisitor;

        impl<'de> Visitor<'de> for AccountsVisitor {
            type Value = RawAccounts;

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
                        return Err(serde::de::Error::custom("duplicate email key"));
                    }
                    let role = map.next_value::<Value>()?;
                    entries.push((email, role));
                }
                Ok(RawAccounts(entries))
            }
        }

        deserializer.deserialize_map(AccountsVisitor)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::{HeaderName, HeaderValue};

    const ISSUER: &str = "https://accounts.example.test";

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

    fn identity_headers(email: &str) -> HeaderMap {
        headers(&[
            (SUBJECT_HEADER, "subject-1"),
            (ISSUER_HEADER, ISSUER),
            (EMAIL_HEADER, email),
            (EMAIL_VERIFIED_HEADER, "true"),
        ])
    }

    #[test]
    fn validates_owner_member_maps_and_normalizes_email_case() {
        let policy = policy(
            r#"{"OWNER@example.com":"owner","Member+tag@example.com":"member","other@example.com":"owner"}"#,
        );
        assert_eq!(policy.accounts.len(), 3);
        assert_eq!(policy.accounts["owner@example.com"], Role::Owner);
        assert_eq!(policy.accounts["member+tag@example.com"], Role::Member);
        assert!(matches!(
            policy
                .request_context(&identity_headers("member@example.com"))
                .unwrap()
                .principal(),
            Principal::Authenticated { role: None, .. }
        ));
    }

    #[test]
    fn rejects_invalid_account_maps() {
        for (json, trusted_issuer) in [
            (r#"{"owner@example.com":"owner"}"#, ""),
            (r#"{"owner@example.com":"owner"}"#, "*"),
            (r#"{"owner@example.com":"owner""#, ISSUER),
            (
                r#"{"owner@example.com":"owner","OWNER@example.com":"member"}"#,
                ISSUER,
            ),
            (r#"{" bad@example.com":"owner"}"#, ISSUER),
            (r#"{"bad..dot@example.com":"owner"}"#, ISSUER),
            (r#"{"a@-bad.example":"owner"}"#, ISSUER),
            (r#"{"owner@example.com":1}"#, ISSUER),
            (r#"{"owner@example.com":"admin"}"#, ISSUER),
            (r#"{"member@example.com":"member"}"#, ISSUER),
        ] {
            assert!(
                AuthPolicy::from_json(json, trusted_issuer).is_err(),
                "{json}"
            );
        }
    }

    #[test]
    fn rejects_duplicate_json_keys_before_map_overwrite() {
        assert_eq!(
            AuthPolicy::from_json(
                r#"{"owner@example.com":"owner","owner@example.com":"member"}"#,
                ISSUER
            )
            .unwrap_err(),
            "authorization account map contains duplicate email keys"
        );
    }

    #[test]
    fn reports_specific_account_map_validation_failures() {
        for (json, expected) in [
            (
                r#"{"owner@example.com":"owner","OWNER@example.com":"member"}"#,
                "authorization account map contains colliding normalized emails",
            ),
            (
                r#"{"owner@example.com":1}"#,
                "authorization account map roles must be strings",
            ),
            (
                r#"{"owner@example.com":"unknown"}"#,
                "authorization account map contains an unknown role",
            ),
            (
                r#"{"member@example.com":"member"}"#,
                "authorization account map must contain an owner",
            ),
            (
                r#"{"owner@example.com":"owner""#,
                "authorization account map is malformed JSON",
            ),
        ] {
            assert_eq!(
                AuthPolicy::from_json(json, ISSUER).unwrap_err(),
                expected,
                "{json}"
            );
        }
    }

    #[test]
    fn missing_and_unreadable_files_fail_without_exposing_contents() {
        let root = std::env::temp_dir().join(format!("auth-policy-{}", uuid::Uuid::new_v4()));
        let missing = root.join("missing.json");
        let missing_error = AuthPolicy::load_from(&missing, ISSUER).unwrap_err();
        assert!(!missing_error.contains("owner@example.com"));

        fs::create_dir_all(&root).unwrap();
        let unreadable_error = AuthPolicy::load_from(&root, ISSUER).unwrap_err();
        assert!(!unreadable_error.contains("owner@example.com"));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn anonymous_and_approved_request_contexts_are_distinguished() {
        let policy = policy(r#"{"owner@example.com":"owner","member@example.com":"member"}"#);
        assert_eq!(
            policy
                .request_context(&HeaderMap::new())
                .unwrap()
                .principal(),
            &Principal::Anonymous
        );
        assert!(matches!(
            policy.request_context(&identity_headers("MEMBER@example.com")).unwrap().principal(),
            Principal::Authenticated { role: Some(Role::Member), email, email_verified: true, .. }
                if email == "member@example.com"
        ));
        assert!(matches!(
            policy
                .request_context(&identity_headers("owner@example.com"))
                .unwrap()
                .principal(),
            Principal::Authenticated {
                role: Some(Role::Owner),
                ..
            }
        ));
        assert!(matches!(
            policy
                .request_context(&identity_headers("outsider@example.com"))
                .unwrap()
                .principal(),
            Principal::Authenticated { role: None, .. }
        ));
    }

    #[test]
    fn unverified_identity_is_authenticated_but_never_gets_a_role() {
        let policy = policy(r#"{"member@example.com":"member","owner@example.com":"owner"}"#);
        for verification in [None, Some("false")] {
            let mut entries = vec![
                (SUBJECT_HEADER, "subject-1"),
                (ISSUER_HEADER, ISSUER),
                (EMAIL_HEADER, "member@example.com"),
            ];
            if let Some(verification) = verification {
                entries.push((EMAIL_VERIFIED_HEADER, verification));
            }
            assert!(matches!(
                policy
                    .request_context(&headers(&entries))
                    .unwrap()
                    .principal(),
                Principal::Authenticated {
                    email_verified: false,
                    role: None,
                    ..
                }
            ));
        }
    }

    #[test]
    fn rejects_invalid_issuer_missing_or_empty_claims_and_duplicate_headers() {
        let policy = policy(r#"{"member@example.com":"member","owner@example.com":"owner"}"#);
        for request_headers in [
            headers(&[
                (SUBJECT_HEADER, "subject-1"),
                (ISSUER_HEADER, "https://untrusted.example"),
                (EMAIL_HEADER, "member@example.com"),
            ]),
            headers(&[(SUBJECT_HEADER, "subject-1"), (ISSUER_HEADER, ISSUER)]),
            headers(&[
                (SUBJECT_HEADER, ""),
                (ISSUER_HEADER, ISSUER),
                (EMAIL_HEADER, "member@example.com"),
            ]),
            headers(&[
                (SUBJECT_HEADER, "subject-1"),
                (ISSUER_HEADER, ISSUER),
                (EMAIL_HEADER, "member@example.com "),
            ]),
        ] {
            assert!(policy.request_context(&request_headers).is_err());
        }

        for name in [
            SUBJECT_HEADER,
            ISSUER_HEADER,
            EMAIL_HEADER,
            EMAIL_VERIFIED_HEADER,
        ] {
            let mut duplicate = identity_headers("member@example.com");
            duplicate.append(name, HeaderValue::from_static("duplicate"));
            assert!(policy.request_context(&duplicate).is_err());
        }
        assert!(policy
            .request_context(&headers(&[(EMAIL_VERIFIED_HEADER, "true")]))
            .is_err());
    }

    #[test]
    fn identity_binding_survives_email_changes_but_not_subject_changes() {
        let initial_policy =
            policy(r#"{"first@example.com":"member","second@example.com":"owner"}"#);
        let first = initial_policy
            .request_context(&identity_headers("first@example.com"))
            .unwrap();
        let second = initial_policy
            .request_context(&identity_headers("second@example.com"))
            .unwrap();
        let first_identity = match first.principal() {
            Principal::Authenticated { identity, .. } => identity,
            _ => unreachable!(),
        };
        let second_identity = match second.principal() {
            Principal::Authenticated { identity, .. } => identity,
            _ => unreachable!(),
        };
        assert_eq!(first_identity, second_identity);
        assert!(matches!(
            first.principal(),
            Principal::Authenticated {
                role: Some(Role::Member),
                ..
            }
        ));
        assert!(matches!(
            second.principal(),
            Principal::Authenticated {
                role: Some(Role::Owner),
                ..
            }
        ));
        assert_ne!(
            AccountIdentity::new(ISSUER.to_owned(), "subject-1".to_owned()).unwrap(),
            AccountIdentity::new(ISSUER.to_owned(), "subject-2".to_owned()).unwrap()
        );
        let same_email_different_subject = initial_policy
            .request_context(&headers(&[
                (SUBJECT_HEADER, "subject-2"),
                (ISSUER_HEADER, ISSUER),
                (EMAIL_HEADER, "first@example.com"),
                (EMAIL_VERIFIED_HEADER, "true"),
            ]))
            .unwrap();
        assert!(matches!(
            same_email_different_subject.principal(),
            Principal::Authenticated { identity, .. } if identity != first_identity
        ));

        let removed_policy =
            policy(r#"{"first@example.com":"member","owner@example.com":"owner"}"#);
        assert!(matches!(
            removed_policy
                .request_context(&identity_headers("second@example.com"))
                .unwrap()
                .principal(),
            Principal::Authenticated { role: None, .. }
        ));
    }

    #[test]
    fn stable_identity_encoding_is_unambiguous_and_round_trips() {
        let first =
            AccountIdentity::new("issuer:with:colons".to_owned(), "subject".to_owned()).unwrap();
        let second =
            AccountIdentity::new("issuer".to_owned(), "with:colons:subject".to_owned()).unwrap();
        assert_ne!(first.stable_key(), second.stable_key());
        assert_eq!(
            AccountIdentity::from_stable_key(&first.stable_key()).unwrap(),
            first
        );
        assert_eq!(
            AccountIdentity::from_stable_key(&second.stable_key()).unwrap(),
            second
        );
        assert!(AccountIdentity::from_stable_key("v1:01:issuer-subject").is_err());
        assert_eq!(first.issuer(), "issuer:with:colons");
        assert_eq!(first.subject(), "subject");
    }

    #[test]
    fn capability_guards_enforce_the_fixed_role_matrix() {
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
            Capability::AdministerAccountPolicy,
        ];
        let member_capabilities = [
            Capability::ReadPublic,
            Capability::ReadAggregateRatings,
            Capability::ReadComments,
            Capability::WriteComments,
            Capability::ReadIndividualRatings,
            Capability::WriteRatings,
        ];
        let owner = RequestContext {
            principal: Principal::Authenticated {
                identity: AccountIdentity::new(ISSUER.to_owned(), "owner".to_owned()).unwrap(),
                email: "owner@example.com".to_owned(),
                email_verified: true,
                role: Some(Role::Owner),
            },
        };
        let member = RequestContext {
            principal: Principal::Authenticated {
                identity: AccountIdentity::new(ISSUER.to_owned(), "member".to_owned()).unwrap(),
                email: "member@example.com".to_owned(),
                email_verified: true,
                role: Some(Role::Member),
            },
        };
        let outsider = RequestContext {
            principal: Principal::Authenticated {
                identity: AccountIdentity::new(ISSUER.to_owned(), "outsider".to_owned()).unwrap(),
                email: "outsider@example.com".to_owned(),
                email_verified: true,
                role: None,
            },
        };

        for capability in capabilities {
            assert!(owner.require(capability).is_ok());
            assert_eq!(
                member.require(capability).is_ok(),
                member_capabilities.contains(&capability)
            );
            assert_eq!(
                RequestContext::anonymous().require(capability).is_ok(),
                matches!(
                    capability,
                    Capability::ReadPublic | Capability::ReadAggregateRatings
                )
            );
            assert_eq!(
                outsider.require(capability).is_ok(),
                matches!(
                    capability,
                    Capability::ReadPublic | Capability::ReadAggregateRatings
                )
            );
        }
        assert_eq!(
            RequestContext::anonymous().require(Capability::WriteComments),
            Err(AuthorizationError {
                status: 401,
                code: "authentication-required"
            })
        );
        assert_eq!(
            member.require(Capability::ManageRecipes),
            Err(AuthorizationError {
                status: 403,
                code: "forbidden"
            })
        );
    }

    #[test]
    fn role_headers_cannot_grant_privileges() {
        let policy = policy(r#"{"member@example.com":"member","owner@example.com":"owner"}"#);
        assert_eq!(
            policy
                .request_context(&headers(&[("authorization", "invalid")]))
                .unwrap()
                .principal(),
            &Principal::Anonymous
        );
        let request_headers = headers(&[
            (SUBJECT_HEADER, "subject-1"),
            (ISSUER_HEADER, ISSUER),
            (EMAIL_HEADER, "outsider@example.com"),
            (EMAIL_VERIFIED_HEADER, "true"),
            ("x-auth-request-role", "owner"),
        ]);
        let context = policy.request_context(&request_headers).unwrap();
        assert!(matches!(
            context.principal(),
            Principal::Authenticated { role: None, .. }
        ));
    }

    #[test]
    fn authorization_errors_have_structured_status_and_code() {
        let unauthenticated = RequestContext::anonymous()
            .require(Capability::WriteRatings)
            .unwrap_err();
        let error = unauthenticated.into_graphql_error();
        assert_eq!(
            error.extensions.as_ref().unwrap().get("status"),
            Some(&async_graphql::Value::from(401))
        );
        assert_eq!(
            error.extensions.as_ref().unwrap().get("code"),
            Some(&async_graphql::Value::from("authentication-required"))
        );
        let forbidden = AuthorizationError::forbidden().into_graphql_error();
        assert_eq!(
            forbidden.extensions.as_ref().unwrap().get("status"),
            Some(&async_graphql::Value::from(403))
        );
        assert_eq!(
            forbidden.extensions.as_ref().unwrap().get("code"),
            Some(&async_graphql::Value::from("forbidden"))
        );
    }
}
