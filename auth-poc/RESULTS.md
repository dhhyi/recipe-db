# Results: OAuth2 Proxy optional authentication with Traefik (#64)

Run on 2026-10-25 with `sh auth-poc/run.sh` on linux/amd64 (Docker 29.8.2, Compose v5.5.1), versions as pinned in [POC.md](./POC.md). Outcome: **88 checks, 80 passed, 8 failed, all 8 failures are registered reproducers, 0 unexpected** (`run.sh` exit 0). The sanitized full run output is preserved in [results/2026-10-25-run.txt](./results/2026-10-25-run.txt); container logs were kept locally only, because they contain one-time authorization codes and state values.

No case is _unavailable/not-run_ in the deterministic matrix. Not verified at all: real Google (see the checklist in [POC.md](./POC.md)), ARM64 execution (manifests only), bearer/service credential validation (#63).

## Summary

| Area (issue matrix) | baseline (`skip_auth_routes`, one router) | split (Traefik routes credentialed requests to strict ForwardAuth) |
| --- | --- | --- |
| 1 Anonymous | pass | pass |
| 2 Valid sessions and roles | pass | pass |
| 3 Spoof resistance, network | pass | pass |
| 4 SSR propagation | n/a (browse uses `/graphql`) | pass, including refresh `Set-Cookie` relay |
| 5 Credential failures | **fail**: malformed, tampered, unknown-ticket and expired cookies and invalid bearer become anonymous 200 | pass: explicit 401 plus clearing cookie; protected actions never reached |
| 6 Infrastructure failures | **fail**: Redis down turns a valid session into anonymous 200; auth down makes public reads 500 | pass: credentialed 401/500, credential-free public reads keep working (200) |
| 7 Session lifecycle | **fail**: replayed post-logout cookie becomes anonymous 200 | pass except 7.5 (OAuth2 Proxy limitation, both modes) |
| 8 Role changes | n/a (GraphQL-only behavior, run on split) | pass |
| 9 Browser mutation protections | n/a (GraphQL/browse behavior, run on split/SSR) | pass |

All baseline failures have the same cause, confirmed in the OAuth2 Proxy v7.15.5 source (`stored_session.go`, `oauthproxy.go`). Any session-load error (bad signature, expired timestamp, missing Redis ticket, Redis unreachable) is logged and the session is cleared and treated as absent. On a `skip_auth_routes` route, `/oauth2/auth` then answers 202 without identity headers. GraphQL therefore cannot tell "no credential" from "credential rejected". Protected actions still failed safely (401, no side effect), but public operations silently returned anonymous results, which the issue forbids. No OAuth2 Proxy option changes this on allowed routes.

## Findings

1. **The split variant needs no adapter.** Strict ForwardAuth is only consulted when the request presents `_oauth2_proxy`/`_oauth2_proxy_N` or any `Authorization` header. Every failure then becomes an explicit 401 with a clearing `Set-Cookie`, relayed by Traefik, and a follow-up request without the cleared cookie reads anonymously. Duplicate `Cookie` headers that hide the session cookie in the second header are still routed strictly (3.6).
2. **`userIDClaim` is a trap.** In v7.15.5 a non-default `oidcConfig.userIDClaim` (for example `sub`) is a deprecated alias that _replaces the email claim_ (`providers.go`) and thereby disables the `email_verified` check (`verifyEmail` only applies when `EmailClaim == "email"`). The first run used `userIDClaim: sub`: email headers carried the subject, and an account with `email_verified=false` signed in successfully. Leave `userIDClaim` unset; `X-Auth-Request-User` is `sub` by default.
3. **A missing `email_verified` claim is accepted by OAuth2 Proxy** (only `false` is rejected). With `additionalClaims: [email_verified]`, the header is empty for such tokens and GraphQL must grant roles only when it is exactly `true` (2.7 passes only because of the target's check).
4. **Refresh replaces the email.** With refreshing sessions, a refresh whose new ID token carries another verified email changes `X-Auth-Request-Email` in place (7.4: the role became none because the new address is not in the map). Email is not a sign-in snapshot; the role map key follows the provider's current email.
5. **Residual risk, preserved as 7.5.** If a refresh returns `email_verified=false`, OAuth2 Proxy treats the unverified-email error as non-fatal and keeps serving the _previous_ verified snapshot. The session is rejected only when the old ID token expires (`validateSession`). In the PoC, member actions succeeded at 25s and 27s and were rejected from 35s (ID-token TTL 30s). With Google the window is up to the ID-token lifetime (~1h). This is not configurable in Traefik or OAuth2 Proxy; it is accepted as low risk because a Google account's verified email becoming unverified is rare. A fatal refresh error (`invalid_grant`, 7.6) clears the session immediately.
6. **Sliding sessions work as amended in #47.** A session active every 25s outlived `cookie_expire` (60s) via three refreshes, and `addAuthCookiesToResponse` delivered the refreshed cookie (7.1); browse relayed it during SSR (4.5). An idle session expired (5.6), and a logged-out cookie was rejected (7.3).
7. **Role-map reload works without a new sign-in.** Demotion and removal took effect on the next request after restarting only the target, with the same session (8.1, 8.2).
8. **OAuth2 Proxy outage.** Split keeps credential-free public reads available (6.A1 200) and fails credentialed requests with Traefik's 500. Baseline fails every request with 500, because ForwardAuth is in the anonymous path.
9. **Network isolation.** With `private` as an `internal` network, the client network could not reach target, OAuth2 Proxy, Redis, the issuer or browse, by name or by IP (3.5). Requesting `Host: graphql.internal` from the edge lands on the same router and authentication boundary (3.4); it is an alias, not a trust zone.

## Proposed contracts (input for #47, #50, #48, #63)

**Identity headers (#47/#50).** Traefik strips client-supplied `X-Auth-Request-*`, `X-Forwarded-User/Email/Groups`, `Gap-Auth` and `Remote-User` on every router, and sets `aliasHeadersStrategy=delete` on the entry point. ForwardAuth copies exactly these response headers:

| Header | Source claim | GraphQL rule |
| --- | --- | --- |
| `X-Auth-Request-User` | `sub` | Required when any identity header is present; stable subject. |
| `X-Auth-Request-Issuer` | `iss` | Must equal the configured issuer, otherwise reject the request. |
| `X-Auth-Request-Email` | `email` | Lowercased lookup key in `/run/secrets/auth-accounts.json`. |
| `X-Auth-Request-Email-Verified` | `email_verified` | Role granted only if exactly `true`; otherwise authenticated, no role. |

No headers means anonymous. Authentication and authorization failures use Problem Details codes such as `authentication-required` (401) and `forbidden` (403), surfaced by GraphQL as `extensions.code`.

**Routing (#50).** Do not use `skip_auth_routes` for the mixed GraphQL route. Use two Traefik routers on the same path. The higher-priority router matches `HeaderRegexp(Cookie, (^|;\s*)_oauth2_proxy(_[0-9]+)?=)` or `HeaderRegexp(Authorization, .)` and uses strict ForwardAuth. The other router has no ForwardAuth. Both strip identity headers first. The cookie regex is coupled to `cookie_name` and must change with it. ForwardAuth settings: `trustForwardHeader: false`, `authRequestHeaders: [Cookie, Authorization]`, `addAuthCookiesToResponse: [_oauth2_proxy]`. `/oauth2/*` is routed only for `start|callback|sign_in|sign_out`.

**Cookie and session.** `_oauth2_proxy` is `HttpOnly`, `SameSite=Lax`, host-only, `Path=/` (and `Secure` in production). Sessions are Redis-backed, with sliding refresh and no absolute deadline.

**SSR forwarding (browse).** Forward only `_oauth2_proxy` and `_oauth2_proxy_N` cookies to GraphQL through Traefik. Never forward or set identity headers. Relay `_oauth2_proxy*` `Set-Cookie` from GraphQL responses to the browser. Mark credentialed pages `Cache-Control: private, no-store` with `Vary: Cookie`, and share-cache only credential-free pages. On 401, render a sign-in-again page and relay the clearing cookie. On other failures return 503, never an anonymous fallback.

**Mutations and CSRF.** GraphQL mutations are POST-only, and CSRF checks run before authentication and side effects: `Sec-Fetch-Site` must be `same-origin`/`none` if present, and `Origin` must be allowlisted if present. Non-JSON bodies (urlencoded, multipart uploads) additionally require the `X-Recipe-Db-CSRF: 1` request header, which cross-site simple requests cannot set. Browse forms require `Origin` equal to the app origin.

**#48 (local/E2E sign-in).** [doubles/mock-oidc.mjs](./doubles/mock-oidc.mjs) shows that an offline issuer exercises the same `provider: oidc` code path as production (`issuerURL: https://accounts.google.com`), including PKCE, refresh and verified-email fixtures. Production should use `provider: oidc` with the Google issuer rather than `provider: google`.

**#63 (MCP/service credentials).** Unresolved. Any `Authorization` header is routed strictly, and OAuth2 Proxy rejects unknown bearers (5.4 split), so MCP or service callers cannot use this route with bearer tokens until bearer validation (`skip_jwt_bearer_tokens` with extra issuers and audiences, or a separate route) and the audience/resource model are decided.

## Recommendation for #50

**Go**, conditional on adopting the split Traefik configuration above instead of `skip_auth_routes`, and on the GraphQL rules in the header contract. No custom adapter is required. The baseline single-router design is **no-go**: it reproducibly downgrades rejected and unverifiable credentials, including Redis outages, to successful anonymous requests. Accept or revisit residual risk 7.5 when finalizing #47.

## Full results

| Case | Mode | Scenario | Expected | Result | Observed (sanitized) |
| --- | --- | --- | --- | --- | --- |
| 1.1 | split | Anonymous read on mixed route | 200, no redirect, no identity headers | PASS | status: 200; identity: none; cacheControl: no-store |
| 1.2 | split | Anonymous protected action (rate) | 401 authentication-required, no side effect | PASS | status: 401; identity: -; code: authentication-required; cacheControl: no-store; sideEffects: 0 |
| 1.2 | split | Anonymous protected action (deleteRecipe) | 401 authentication-required, no side effect | PASS | status: 401; identity: -; code: authentication-required; cacheControl: no-store; sideEffects: 0 |
| 2.1 | split | Valid owner session identity | 200, issuer+subject+verified email, role=owner | PASS | status: 200; identity: sub-owner owner@example.test verified=true role=owner; cacheControl: no-store |
| 2.1 | split | Valid member session identity | 200, issuer+subject+verified email, role=member | PASS | status: 200; identity: sub-member member@example.test verified=true role=member; cacheControl: no-store |
| 2.1 | split | Valid outsider session identity | 200, issuer+subject+verified email, role=none | PASS | status: 200; identity: sub-outsider outsider@example.test verified=true role=none; cacheControl: no-store |
| 2.2 | split | Member performs member action (rate) | 200, one side effect | PASS | status: 200; identity: none; cacheControl: no-store; sideEffects: 1 |
| 2.3 | split | Member attempts owner-only action | 403 forbidden, no side effect | PASS | status: 403; identity: -; code: forbidden; cacheControl: no-store; sideEffects: 0 |
| 2.4 | split | Owner performs owner-only action | 200, one side effect | PASS | status: 200; identity: none; cacheControl: no-store; sideEffects: 1 |
| 2.5 | split | Authenticated non-allowlisted account attempts member action | 403 forbidden, no side effect | PASS | status: 403; identity: -; code: forbidden; cacheControl: no-store; sideEffects: 0 |
| 1.1 | baseline | Anonymous read on mixed route | 200, no redirect, no identity headers | PASS | status: 200; identity: none; cacheControl: no-store |
| 1.2 | baseline | Anonymous protected action (rate) | 401 authentication-required, no side effect | PASS | status: 401; identity: -; code: authentication-required; cacheControl: no-store; sideEffects: 0 |
| 1.2 | baseline | Anonymous protected action (deleteRecipe) | 401 authentication-required, no side effect | PASS | status: 401; identity: -; code: authentication-required; cacheControl: no-store; sideEffects: 0 |
| 2.1 | baseline | Valid owner session identity | 200, issuer+subject+verified email, role=owner | PASS | status: 200; identity: sub-owner owner@example.test verified=true role=owner; cacheControl: no-store |
| 2.1 | baseline | Valid member session identity | 200, issuer+subject+verified email, role=member | PASS | status: 200; identity: sub-member member@example.test verified=true role=member; cacheControl: no-store |
| 2.1 | baseline | Valid outsider session identity | 200, issuer+subject+verified email, role=none | PASS | status: 200; identity: sub-outsider outsider@example.test verified=true role=none; cacheControl: no-store |
| 2.2 | baseline | Member performs member action (rate) | 200, one side effect | PASS | status: 200; identity: none; cacheControl: no-store; sideEffects: 1 |
| 2.3 | baseline | Member attempts owner-only action | 403 forbidden, no side effect | PASS | status: 403; identity: -; code: forbidden; cacheControl: no-store; sideEffects: 0 |
| 2.4 | baseline | Owner performs owner-only action | 200, one side effect | PASS | status: 200; identity: none; cacheControl: no-store; sideEffects: 1 |
| 2.5 | baseline | Authenticated non-allowlisted account attempts member action | 403 forbidden, no side effect | PASS | status: 403; identity: -; code: forbidden; cacheControl: no-store; sideEffects: 0 |
| 2.6 | proxy | Sign-in with email_verified=false (allowlisted address) | sign-in rejected, no session cookie | PASS | status: 500 |
| 2.7 | split | ID token without email_verified claim (allowlisted address) | no member rights | PASS | status: 200; identity: sub-missing-verified member@example.test verified=false role=none; cacheControl: no-store; loginStatus: 302; admittedBySession: true; actionStatus: 403; sideEffects: 0 |
| 2.7 | baseline | ID token without email_verified claim (allowlisted address) | no member rights | PASS | status: 200; identity: sub-missing-verified member@example.test verified=false role=none; cacheControl: no-store; loginStatus: 302; admittedBySession: true; actionStatus: 403; sideEffects: 0 |
| 2.8 | proxy | Session cookie attributes after sign-in | HttpOnly, SameSite=Lax, Path=/, no Domain | PASS | status: 302; location: http://app.poc.test/browse/page; setCookie: ["_oauth2_proxy_XMtRw-A6_csrf=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax","_oauth2_proxy=<redacted>; Path=/; Max-Age=60; HttpOnly; SameSite=Lax"] |
| 3.1 | split | Anonymous request with forged identity/role headers | anonymous, no trusted identity header reaches target | PASS | status: 200; identity: none; cacheControl: no-store; ignoredHeadersReceived: ["x-role","x-user-role"] |
| 3.2 | split | Anonymous owner action with forged headers | 401, no side effect | PASS | status: 401; identity: -; code: authentication-required; cacheControl: no-store; sideEffects: 0 |
| 3.3 | split | Member session with forged owner headers | member identity only; owner action 403, no side effect | PASS | status: 200; identity: sub-member member@example.test verified=true role=member; cacheControl: no-store; trustedIdentityHeadersReceived: ["x-auth-request-email","x-auth-request-email-verified","x-auth-request-issuer","x-auth-request-user"]; actionStatus: 403; sideEffects: 0 |
| 3.4 | split | Internal hostname (graphql.internal) requested from edge with forged headers | same auth boundary: anonymous | PASS | status: 200; identity: none; cacheControl: no-store |
| 3.1 | baseline | Anonymous request with forged identity/role headers | anonymous, no trusted identity header reaches target | PASS | status: 200; identity: none; cacheControl: no-store; ignoredHeadersReceived: ["x-role","x-user-role"] |
| 3.2 | baseline | Anonymous owner action with forged headers | 401, no side effect | PASS | status: 401; identity: -; code: authentication-required; cacheControl: no-store; sideEffects: 0 |
| 3.3 | baseline | Member session with forged owner headers | member identity only; owner action 403, no side effect | PASS | status: 200; identity: sub-member member@example.test verified=true role=member; cacheControl: no-store; trustedIdentityHeadersReceived: ["x-auth-request-email","x-auth-request-email-verified","x-auth-request-issuer","x-auth-request-user"]; actionStatus: 403; sideEffects: 0 |
| 3.4 | baseline | Internal hostname (graphql.internal) requested from edge with forged headers | same auth boundary: anonymous | PASS | status: 200; identity: none; cacheControl: no-store |
| 3.5 | network | Direct access to private services from client network | no connection by name or IP | PASS | target:8080: timeout; oauth2-proxy:4180: timeout; redis:6379: timeout; mock-oidc:8080: timeout; browse:8080: timeout; target-ip:8080: timeout |
| 3.6 | split | Duplicate Cookie headers hiding a malformed session cookie in the second header | non-success (credential presented) | PASS | status: 401; identity: -; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"] |
| 4.1 | ssr | Anonymous SSR page | 200 anonymous, shareable cache headers | PASS | status: 200; identity: none; cacheControl: public, max-age=60; browseCache: miss |
| 4.2 | ssr | Member SSR page forwards only the session cookie | 200 member identity, private no-store, only _oauth2_proxy forwarded, no forged headers | PASS | status: 200; identity: sub-member member@example.test verified=true role=member; cacheControl: private, no-store; forwardedCookieNames: ["_oauth2_proxy"]; receivedIdentityHeaders: ["x-auth-request-email","x-auth-request-email-verified","x-auth-request-issuer","x-auth-request-user"]; browseCache: bypass |
| 4.3 | ssr | Anonymous SSR page after authenticated page | anonymous content, no identity leak from shared cache | PASS | status: 200; identity: none; cacheControl: public, max-age=60; browseCache: hit |
| 4.4 | ssr | SSR page with tampered session cookie | 401 sign-in page, clearing cookie relayed; next credential-free page anonymous | PASS | status: 401; identity: -; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"]; cacheControl: private, no-store; nextStatus: 200; cookieClearedInBrowser: true |
| 5.0 | split | Control: re-signed copy of a valid cookie | 200 member (validates the signing helper used for 5.3) | PASS | status: 200; identity: sub-member member@example.test verified=true role=member; cacheControl: no-store |
| 5.1 | split | Presented malformed session cookie | explicit non-success; protected action without side effect; cleared cookie then allows anonymous read | PASS | status: 401; identity: -; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"]; actionStatus: 401; sideEffects: 0; afterClearing: 200; cookieCleared: true |
| 5.2 | split | Presented tampered session cookie | explicit non-success; protected action without side effect; cleared cookie then allows anonymous read | PASS | status: 401; identity: -; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"]; actionStatus: 401; sideEffects: 0; afterClearing: 200; cookieCleared: true |
| 5.3 | split | Presented unknown ticket (validly signed) session cookie | explicit non-success; protected action without side effect; cleared cookie then allows anonymous read | PASS | status: 401; identity: -; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"]; actionStatus: 401; sideEffects: 0; afterClearing: 200; cookieCleared: true |
| 5.4 | split | Presented invalid bearer credential | explicit non-success | PASS | status: 401; identity: -; actionStatus: 401; sideEffects: 0 |
| 5.0 | baseline | Control: re-signed copy of a valid cookie | 200 member (validates the signing helper used for 5.3) | PASS | status: 200; identity: sub-member member@example.test verified=true role=member; cacheControl: no-store |
| 5.1 | baseline | Presented malformed session cookie | explicit non-success; protected action without side effect; cleared cookie then allows anonymous read | FAIL (preserved reproducer) | status: 200; identity: none; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"]; cacheControl: no-store; actionStatus: 401; sideEffects: 0; afterClearing: 200; cookieCleared: true |
| 5.2 | baseline | Presented tampered session cookie | explicit non-success; protected action without side effect; cleared cookie then allows anonymous read | FAIL (preserved reproducer) | status: 200; identity: none; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"]; cacheControl: no-store; actionStatus: 401; sideEffects: 0; afterClearing: 200; cookieCleared: true |
| 5.3 | baseline | Presented unknown ticket (validly signed) session cookie | explicit non-success; protected action without side effect; cleared cookie then allows anonymous read | FAIL (preserved reproducer) | status: 200; identity: none; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"]; cacheControl: no-store; actionStatus: 401; sideEffects: 0; afterClearing: 200; cookieCleared: true |
| 5.4 | baseline | Presented invalid bearer credential | explicit non-success | FAIL (preserved reproducer) | status: 200; identity: none; cacheControl: no-store; actionStatus: 401; sideEffects: 0 |
| 5.5 | split | Expired-timestamp cookie (validly signed, older than cookie_expire) | explicit non-success | PASS | status: 401; identity: -; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"] |
| 9.1 | ssr | Cross-site SSR form POST with member cookie | 403 before side effects | PASS | status: 403; identity: -; cacheControl: private, no-store; sideEffects: 0 |
| 9.2 | ssr | SSR form POST without Origin | 403 before side effects | PASS | status: 403; identity: -; cacheControl: private, no-store; sideEffects: 0 |
| 9.3 | ssr | Same-origin SSR form POST (positive control) | 200, one side effect | PASS | status: 200; identity: none; cacheControl: private, no-store; sideEffects: 1 |
| 9.4 | ssr | Anonymous same-origin SSR form POST | 401 sign-in page, no side effect, no replay | PASS | status: 401; identity: -; cacheControl: private, no-store; sideEffects: 0 |
| 9.5 | split | Cross-site multipart upload (simple request, no preflight) | 403 csrf-rejected, no side effect | PASS | status: 403; identity: -; code: csrf-rejected; cacheControl: no-store; sideEffects: 0 |
| 9.6 | split | Multipart upload without CSRF request header (old browser: no Origin/Fetch Metadata) | 403 csrf-rejected, no side effect | PASS | status: 403; identity: -; code: csrf-rejected; cacheControl: no-store; sideEffects: 0 |
| 9.7 | split | Same-origin multipart upload with X-Recipe-Db-Csrf header (positive control) | 200, one side effect | PASS | status: 200; identity: none; cacheControl: no-store; sideEffects: 1 |
| 9.8 | split | Cross-site urlencoded POST to GraphQL | 403 csrf-rejected, no side effect | PASS | status: 403; identity: -; code: csrf-rejected; cacheControl: no-store; sideEffects: 0 |
| 7.2 | proxy | Logout | redirect, session cookie cleared | PASS | status: 302; identity: -; location: http://app.poc.test/browse/page; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"]; cacheControl: no-cache, no-store, must-revalidate, max-age=0 |
| 7.3 | split | Replay pre-logout cookie (deleted ticket) | explicit non-success; no side effect | PASS | status: 401; identity: -; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"]; actionStatus: 401; sideEffects: 0 |
| 7.3 | baseline | Replay pre-logout cookie (deleted ticket) | explicit non-success; no side effect | FAIL (preserved reproducer) | status: 200; identity: none; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"]; cacheControl: no-store; actionStatus: 401; sideEffects: 0 |
| 7.6 | split | Provider rejects refresh token (invalid_grant) | explicit non-success, session cleared | PASS | status: 401; identity: -; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax","_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"] |
| 7.4 | split | Refresh returns a changed verified email | stable subject; observe whether email is the sign-in snapshot | PASS | before: sub-email-change member@example.test verified=true role=member; after: sub-email-change changed@example.test verified=true role=none; emailUpdatedOnRefresh: true |
| 4.5 | ssr | Session refresh triggered during SSR | refresh Set-Cookie relayed by browse to the browser; session keeps working | PASS | status: 200; identity: none; setCookie: ["_oauth2_proxy=<redacted>; Path=/; Max-Age=60; HttpOnly; SameSite=Lax"]; cacheControl: private, no-store; relayedSessionCookies: 1; followUp: 200 |
| 7.5 | split | Refresh returns email_verified=false (ID token TTL 30s, refresh after 20s) | no member rights on any request after the refresh | FAIL (preserved reproducer) | requests: ["25s:whoami=200/true/member,rate=200","27s:whoami=200/true/member,rate=200","35s:whoami=401/-/-,rate=401","45s:whoami=200/-/-,rate=401"]; sideEffects: 2 |
| 5.6 | split | Natural expiry: cookie presented after 70s idle (cookie_expire 60s) | explicit non-success; no side effect | PASS | status: 401; identity: -; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"]; actionStatus: 401; sideEffects: 0 |
| 5.6 | baseline | Natural expiry: cookie presented after 70s idle (cookie_expire 60s) | explicit non-success; no side effect | FAIL (preserved reproducer) | status: 200; identity: none; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"]; cacheControl: no-store; actionStatus: 401; sideEffects: 0 |
| 7.1 | split | Active session across refresh beyond cookie_expire (60s) from original sign-in | renewed sliding session; refresh Set-Cookie reaches client | PASS | requests: ["0s:200:member","25s:200:member","50s:200:member","75s:200:member"]; refreshSetCookies: 3 |
| 6.R1 | split | redis stopped: request without credentials | public read may succeed anonymously (no credential presented) | PASS | status: 200; identity: none; cacheControl: no-store |
| 6.R2 | split | redis stopped: request with valid session cookie | explicit non-success, not anonymous success | PASS | status: 401; identity: -; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"] |
| 6.R3 | split | redis stopped: protected action with valid session cookie | non-success, no side effect | PASS | status: 401; identity: -; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"]; sideEffects: 0 |
| 6.R1 | baseline | redis stopped: request without credentials | public read may succeed anonymously (no credential presented) | PASS | status: 200; identity: none; cacheControl: no-store |
| 6.R2 | baseline | redis stopped: request with valid session cookie | explicit non-success, not anonymous success | FAIL (preserved reproducer) | status: 200; identity: none; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"]; cacheControl: no-store |
| 6.R3 | baseline | redis stopped: protected action with valid session cookie | non-success, no side effect | PASS | status: 401; identity: -; code: authentication-required; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"]; cacheControl: no-store; sideEffects: 0 |
| 6.R4 | ssr | redis stopped: SSR page with valid session cookie | explicit non-success page, not anonymous HTML | PASS | status: 401; identity: -; setCookie: ["_oauth2_proxy=<cleared>; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"]; cacheControl: private, no-store |
| 6.R5 | split | redis recovered: same session cookie | member identity restored, no escalation | PASS | status: 200; identity: sub-member member@example.test verified=true role=member; cacheControl: no-store |
| 6.R5 | baseline | redis recovered: same session cookie | member identity restored, no escalation | PASS | status: 200; identity: sub-member member@example.test verified=true role=member; cacheControl: no-store |
| 6.A1 | split | oauth2-proxy stopped: request without credentials | public read may succeed anonymously (no credential presented) | PASS | status: 200; identity: none; cacheControl: no-store |
| 6.A2 | split | oauth2-proxy stopped: request with valid session cookie | explicit non-success, not anonymous success | PASS | status: 500; identity: - |
| 6.A3 | split | oauth2-proxy stopped: protected action with valid session cookie | non-success, no side effect | PASS | status: 500; identity: -; sideEffects: 0 |
| 6.A1 | baseline | oauth2-proxy stopped: request without credentials | public read may succeed anonymously (no credential presented) | PASS | status: 500; identity: - |
| 6.A2 | baseline | oauth2-proxy stopped: request with valid session cookie | explicit non-success, not anonymous success | PASS | status: 500; identity: - |
| 6.A3 | baseline | oauth2-proxy stopped: protected action with valid session cookie | non-success, no side effect | PASS | status: 500; identity: -; sideEffects: 0 |
| 6.A4 | ssr | oauth2-proxy stopped: SSR page with valid session cookie | explicit non-success page, not anonymous HTML | PASS | status: 503; identity: -; cacheControl: private, no-store |
| 6.A5 | split | oauth2-proxy recovered: same session cookie | member identity restored, no escalation | PASS | status: 200; identity: sub-member member@example.test verified=true role=member; setCookie: ["_oauth2_proxy=<redacted>; Path=/; Max-Age=60; HttpOnly; SameSite=Lax"]; cacheControl: no-store |
| 6.A5 | baseline | oauth2-proxy recovered: same session cookie | member identity restored, no escalation | PASS | status: 200; identity: sub-member member@example.test verified=true role=member; cacheControl: no-store |
| 8.0 | split | Roles before map change | owner=owner, member=member | PASS | owner: sub-owner owner@example.test verified=true role=owner; member: sub-member member@example.test verified=true role=member |
| 8.1 | split | Demoted owner keeps session; next request uses new map | role=member; owner action 403 without side effect; member action allowed | PASS | status: 200; identity: sub-owner owner@example.test verified=true role=member; cacheControl: no-store; deleteStatus: 403; deleteEffects: 0; rateStatus: 200; rateEffects: 1 |
| 8.2 | split | Removed member keeps session; next request has no member rights | role=none; member action 403 without side effect | PASS | status: 200; identity: sub-member member@example.test verified=true role=none; cacheControl: no-store; actionStatus: 403; sideEffects: 0 |
| 88 checks: 80 passed, 8 failed, 0 unexpected. |
