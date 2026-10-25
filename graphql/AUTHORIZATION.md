# GraphQL authorization foundation

At startup, GraphQL reads the read-only mounted file `/run/secrets/auth-accounts.json`. Compose mounts the untracked local file `./.secrets/auth-accounts.json` there; k3s should mount a Secret at the same path. The fixed file has this shape:

```json
{
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

All three top-level sections are required. Roles are `anonymous`, `member`, or `owner`; the anonymous principal can intentionally have any of those roles in every environment. Token and Google-account collections may be empty, and no owner entry is required. Token IDs and secrets must be unique and nonempty. Optional `displayName` values are descriptive only; identity is never based on a display name, email, or token secret. Configuration errors do not include config values or token secrets.

Google email keys and incoming addresses use conservative ASCII dot-atom local parts and DNS-style domains with at least two labels. Addresses are lowercased for lookup; no provider-specific aliases are merged. Google identity uses a namespaced, unambiguous issuer/subject key, so email changes preserve identity and different subjects remain distinct. `AUTH_TRUSTED_ISSUER` must be explicitly configured. Only an exactly verified email can receive its configured Google role; an outsider or unverified identity receives the effective `anonymous` role, not the credential-free principal's configured role.

GraphQL validates one bearer `Authorization` header against configured token secrets using a constant-time comparison. The resulting namespaced principal ID is based on the configured token ID, so rotating a secret does not change its identity. Unknown, empty, malformed, or duplicate authorization headers fail authentication and never fall back to the configured credential-free principal. A token and any trusted Google identity headers on the same request are rejected rather than combined.

Requests without a bearer credential or trusted Google identity headers use the shared `credential-free:v1` principal and the configured `anonymous` role/name. All such callers share this identity, so attribution cannot distinguish individual credential-free users. The trusted Google headers are `X-Auth-Request-User`, `X-Auth-Request-Issuer`, `X-Auth-Request-Email`, and optional `X-Auth-Request-Email-Verified`. Identity headers are accepted only behind the sanitization and network boundary being integrated separately; this foundation does not make direct GraphQL access safe.

The `anonymous` role permits public reads and aggregate ratings. `member` additionally permits comments and individual ratings; `owner` adds recipe, import, and image management. The same capability checks apply to principals from every identity source, including intentionally privileged credential-free principals. The current work supplies reusable guards and does not wire them to existing fields.

The file is loaded once at startup, and each request resolves its principal against that loaded configuration. Replacing the file alone does not reload policy; restart GraphQL to apply role changes or token additions/removals. Do not declare a multi-replica policy rollout complete while any serving replica still has the previous configuration. Successful library-managed browser-session refresh may update verified email. If refresh is rejected because email is unverified, the previous validated identity may remain usable until its existing token expires; this accepted upstream limitation is not custom refresh logic.

Schema printing does not load this file or require the auth provider. CI uses an intentionally credential-free, read-only configuration fixture.
