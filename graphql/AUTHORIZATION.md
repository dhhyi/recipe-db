# GraphQL authorization foundation

At startup, GraphQL reads the read-only mounted file `/run/secrets/auth-accounts.json`. Compose mounts the untracked local file `./.secrets/auth-accounts.json` there; k3s should mount a Secret at the same path. The fixed file has this shape:

```json
{
  "$schema": "../graphql/auth-accounts.schema.json",
  "anonymous": { "role": "anonymous", "displayName": "Guest" },
  "tokens": [
    {
      "id": "personal-mcp",
      "secret": "replace-with-a-random-secret",
      "role": "owner"
    }
  ],
  "googleAccounts": {
    "owner@example.com": "owner",
    "family@example.com": "member"
  }
}
```

For the standalone GraphQL devcontainer, create the same file at the repository root as `.secrets/auth-accounts.json`. The `Run watch server` task copies it to `/run/secrets/auth-accounts.json` as a root-owned read-only file before starting GraphQL, and sets `AUTH_TRUSTED_ISSUER` to `https://accounts.google.com`. Restart the task after changing the file; it is not hot-reloaded. Do not commit the local secret file.

The JSON Schema at [`auth-accounts.schema.json`](auth-accounts.schema.json) provides editor validation; the `$schema` path above is relative to `.secrets/auth-accounts.json`. All three top-level sections are required. Roles are `anonymous`, `member`, or `owner`; the anonymous principal can intentionally have any of those roles in every environment. Token and Google-account collections may be empty, and no owner entry is required. Token IDs and secrets must be unique and nonempty. Optional `displayName` values are descriptive only; identity is never based on a display name, email, or token secret. Configuration errors do not include config values or token secrets.

GraphQL validates the configuration at startup using its strict Serde parser; the JSON Schema is for IDE feedback and is not a second runtime validator. The email-key pattern in the schema is intentionally a basic editor check; runtime validation is stricter and authoritative. Enforcing JSON Schema at startup would require adding a schema-validation dependency and keeping its rules synchronized with the existing semantic checks (for duplicate normalized email keys and token values, for example). A separate mini binary would duplicate the same validation and add another tool to maintain, so it is not needed for startup safety.

Google email keys and incoming addresses use conservative ASCII dot-atom local parts and DNS-style domains with at least two labels. Addresses are lowercased for lookup; no provider-specific aliases are merged. Google identity uses a namespaced, unambiguous issuer/subject key, so email changes preserve identity and different subjects remain distinct. `AUTH_TRUSTED_ISSUER` must be explicitly configured. Only an exactly verified email can receive its configured Google role; an outsider or unverified identity receives the effective `anonymous` role, not the credential-free principal's configured role.

GraphQL validates one bearer `Authorization` header against configured token secrets using a constant-time comparison. The resulting namespaced principal ID is based on the configured token ID, so rotating a secret does not change its identity. Unknown, empty, malformed, or duplicate authorization headers fail authentication and never fall back to the configured credential-free principal. A token and any trusted Google identity headers on the same request are rejected rather than combined.

Requests without a bearer credential or trusted Google identity headers use the shared `credential-free:v1` principal and the configured `anonymous` role/name. All such callers share this identity, so attribution cannot distinguish individual credential-free users. The trusted Google headers are `X-Auth-Request-User`, `X-Auth-Request-Issuer`, `X-Auth-Request-Email`, and optional `X-Auth-Request-Email-Verified`. Production ingress strips identity aliases before routing, and GraphQL rejects `/graphql` requests without exactly one matching `X-Internal-Ingress-Token`. The independent deployment secret is loaded from `/run/secrets/graphql-ingress-secret`, compared in constant time, and the header is removed before application handling. Traefik injects it only after sanitization/authentication; it is not a user credential or role. Development networking is not a production security boundary and does not enforce this token. See [browser authentication](../docs/browser-authentication.md) for provisioning, rotation, ingress and SSR contracts.

The `anonymous` role permits public reads and aggregate ratings. `member` additionally permits own-vote access and rating writes; `owner` adds recipe, import, image, and test-reset management. The same capability checks apply to principals from every identity source, including intentionally privileged credential-free principals.

## Application operation mapping

| GraphQL field or route | Required capability | Anonymous | Member | Owner |
| --- | --- | --- | --- | --- |
| `recipe`, `recipes`, `searchRecipes`, nested recipe ingredients/method/image/inspirations/link metadata | `ReadPublic` | Allow | Allow | Allow |
| `rating` and nested aggregate average/count | `ReadAggregateRatings` | Allow | Allow | Allow |
| `Rating.myRating` | `ReadIndividualRatings` | Deny | Own vote only | Own vote only |
| `rate` | `WriteRatings` | Deny | Allow | Allow |
| `createRecipe`, `updateRecipe`, `deleteRecipe` | `ManageRecipes` | Deny | Deny | Allow |
| Inspiration changes in create/update | `ManageImports` | Deny | Deny | Allow |
| `setImage` | `ManageImages` | Deny | Deny | Allow |
| `myCapabilities`, `onlineServices`, `isServiceOnline`, `allServicesOnline` | Effective current principal / public availability | Allow | Allow | Allow |

These are field resolver checks, so GraphQL aliases and nested/composed calls use the same authorization path. `myRating` is nullable and only reads the current principal's vote; no argument accepts another user ID. A missing vote is `null`, while insufficient capability is a structured `authentication-required` or `forbidden` error. Public aggregate fields remain independently nullable only when their existing backend availability contract says so.

Mutations check capabilities before any REST write, event publication, or upload processing. Recipe updates that also change inspirations check both recipe and import capabilities before either backend is touched. Service reset APIs are private REST routes enabled only by explicit `MODE=testing`; they are not exposed through GraphQL or MCP.

`MODE` accepts `production` (the default when unset) or `testing`; empty and unsupported values fail startup. Production mode requires trusted ingress and disables GraphiQL and schema introspection.

Rating attribution is the namespaced stable principal ID from the request context, never a caller-provided login, display name, email, or token secret. The ratings backend stores only that ID and enforces `(recipeId, userId)` uniqueness. Existing disposable development ratings created with the former login key are discarded when the old table schema is encountered; there is no production ratings migration or account-guessing step.

The file is loaded once at startup, and each request resolves its principal against that loaded configuration. Replacing the file alone does not reload policy; restart GraphQL to apply role changes or token additions/removals. Do not declare a multi-replica policy rollout complete while any serving replica still has the previous configuration. Successful library-managed browser-session refresh may update verified email. If refresh is rejected because email is unverified, the previous validated identity may remain usable until its existing token expires; this accepted upstream limitation is not custom refresh logic.

Schema printing does not load this file or require the auth provider. CI uses an intentionally credential-free, read-only configuration fixture.
