# OAuth2 Proxy optional-authentication PoC (#64)

Bounded, disposable experiment for [#64](https://github.com/dhhyi/recipe-db/issues/64). It is not a production implementation and is not wired into the generated Compose stack, Bazel targets or any project. Results and the recommendation are in [RESULTS.md](./RESULTS.md).

## Run

From the repository root on a Docker host (no Google credentials, no network access beyond pulling the pinned images):

```sh
sh auth-poc/run.sh > /tmp/$(date +%F-%H%M%S)-auth-poc-run.log 2>&1
AUTH_POC_LOG=/tmp/auth-poc-compose.log sh auth-poc/run.sh # optional: choose where container logs are kept
```

`run.sh` takes about four minutes. It:

1. refuses to start if Compose project `recipe-db-auth-poc` already exists;
2. creates an ephemeral `mktemp` directory holding a random cookie secret, a random OIDC client secret and the role map `auth-accounts.json` (`owner@example.test` owner, `member@example.test` member, `backup-owner@example.test` owner);
3. starts the stack with `docker compose up --wait`;
4. runs the matrix phases with the `runner` service (`wait`, `main`, `lifecycle`, `infra-prepare`, `redis-down`, `redis-recovered`, `auth-down`, `auth-recovered`, `roles-before`, `roles-after`, `report`), stopping/starting Redis and OAuth2 Proxy and rewriting the role map plus restarting only `target` between phases;
5. prints the sanitized results table (`report`) and exits non-zero only on _unexpected_ results — a known gap that reproduces, or a check that is neither passing nor a registered reproducer;
6. always writes all container logs to `AUTH_POC_LOG` (default `/tmp/auth-poc-compose.log`), then runs `docker compose --profile runner down --volumes --remove-orphans` for its own project only and deletes the secret directory, also on failure or interrupt.

Manual cleanup if the host process was killed: `docker compose -p recipe-db-auth-poc --profile runner down --volumes --remove-orphans` (requires `AUTH_POC_SECRETS` set to any existing directory for interpolation).

## Topology

| Service | Role | Networks |
| --- | --- | --- |
| `traefik` | Only entry point. `app.poc.test` (app) and `idp.poc.test` (mock issuer) on `edge`; `graphql.internal` and `idp.poc.test` aliases on `private`. | edge, private |
| `oauth2-proxy` | ForwardAuth endpoint `/oauth2/auth` and `/oauth2/*` sign-in, callback and sign-out. | private |
| `redis` | Server-side session store (AOF, `appendfsync always`, so sessions survive a Redis restart). | private |
| `mock-oidc` | Deterministic offline OIDC issuer: RS256, discovery, JWKS, PKCE S256, client authentication, refresh grant without rotation (like Google), fixtures. | private |
| `target` | GraphQL stand-in: reads the role map at startup, trusts only `X-Auth-Request-*`, applies CSRF then authentication then role checks, logs side effects. | private |
| `browse` | SSR stand-in: forwards only `_oauth2_proxy*` cookies to `http://graphql.internal/graphql` via Traefik, relays refresh `Set-Cookie`, guards its form. | private |
| `runner` | Simulated untrusted browser/client, attached only to `edge` (profile `runner`). | edge |

`private` is a Docker `internal` network: the client network has no route to private services by name or IP (case 3.5). Traefik is the only service on both networks.

Two GraphQL routings are measured side by side on the same target:

- **baseline** `/baseline/graphql`: one router, ForwardAuth always consulted, anonymous access granted by OAuth2 Proxy `skip_auth_routes` (the shape described in #50).
- **split** `/graphql`: a configuration-only Traefik variant. A higher-priority router matches requests that present the session cookie (`(^|;\s*)_oauth2_proxy(_[0-9]+)?=`) or any `Authorization` header and sends them to strict ForwardAuth (no skip route). Requests without any credential use a router without ForwardAuth. Both routers strip client-supplied identity headers first.

## Pinned versions

All images are referenced by tag and digest in [compose.yaml](./compose.yaml). Their manifest lists include `linux/arm64`; the PoC was executed on `linux/amd64` only, so ARM64 execution is not verified.

| Component | Image |
| --- | --- |
| OAuth2 Proxy | `quay.io/oauth2-proxy/oauth2-proxy:v7.15.5@sha256:8498b0d0ef0a7b29686414000a08aee467f02d0299c9ed1e006a8f33fc017916` |
| Traefik | `traefik:v3.7.16@sha256:c8a121e4bb1347e8fd52657fab12f2cb70b68f8a018895e2068f92c9e519b9c2` |
| Redis | `redis:8.10.2-alpine@sha256:0bf6577d7774e592b29d093e3ac9390eb91e13d72c21e506afce736de5e0eeb0` |
| Node.js | `node:24.22.1-alpine@sha256:06d7adf3e0ef61a13f1d28682726366f97a15aa1888c934d3ecec86c33918b53` (doubles, runner) |

Executed with Docker Engine 29.8.2 and Docker Compose v5.5.1.

## Settings under test

- OAuth2 Proxy ([oauth2-proxy.cfg](./oauth2-proxy/oauth2-proxy.cfg), [alpha.yaml](./oauth2-proxy/alpha.yaml)): `provider: oidc`, scope `openid email`, PKCE S256, `insecureAllowUnverifiedEmail: false`, `emailClaim: email`, `additionalClaims: [iss, email_verified]`, `email_domains = *` (authorization belongs to GraphQL), Redis session store, cookie `_oauth2_proxy` (`HttpOnly`, `SameSite=Lax`, host-only, `Secure` off only because the PoC is plain HTTP), `cookie_expire 60s`, `cookie_refresh 20s`, per-request login CSRF cookies, `reverse_proxy` with `trusted_proxy_ips` limited to the private subnet. Short durations make expiry and refresh deterministic; production values are a separate decision.
- Response headers to Traefik: `X-Auth-Request-User` (`sub`), `X-Auth-Request-Email`, `X-Auth-Request-Issuer`, `X-Auth-Request-Email-Verified`.
- Traefik ([dynamic.yml](./traefik/dynamic.yml)): `strip-identity` blanks identity-like request headers; `oauth2-auth` ForwardAuth with `trustForwardHeader: false`, `authRequestHeaders: [Cookie, Authorization]`, exactly the four `authResponseHeaders`, `addAuthCookiesToResponse: [_oauth2_proxy]`; entry point `http.aliasHeadersStrategy=delete` removes `X_Auth_…`/`X.Auth…` aliases.
- Mock issuer tokens live 30s; refresh tokens are not rotated and refresh responses omit `refresh_token`, like Google.

## Limitations

- Mock issuer only. Real Google behavior (consent, `access_type=offline`, refresh-token availability, claim contents) is not verified; see the checklist below.
- Plain HTTP, so the `Secure` cookie attribute and HSTS are not exercised.
- `target` and `browse` are minimal doubles that model the proposed contracts; they do not prove the Rust GraphQL or Elm/Lustre browse implementations.
- Bearer/service credentials (#63) are only checked for rejection of an invalid token; no bearer validation was configured.
- Single OAuth2 Proxy and Redis instance; no HA, load or upgrade behavior.
- The cookie-secret is given to the runner solely to forge a correctly signed cookie that references a non-existent ticket (case 5.3, validated by the re-signing control 5.0).

## Optional real-Google smoke checklist (not executed)

Real-Google integration is **not verified** by this PoC. A later manual smoke test should cover:

1. Google Cloud project with an OAuth consent screen and a _Web application_ OAuth client; authorized redirect URI exactly `https://<public host>/oauth2/callback` and no wildcard origins.
2. OAuth2 Proxy `provider: oidc` with `issuerURL: https://accounts.google.com` (same code path as the mock), scope `openid email`, PKCE S256.
3. Refresh tokens: Google only issues one with `access_type=offline` (and `prompt=consent` for repeat grants); confirm the session survives past the ~1h ID-token lifetime via refresh, and observe behavior when the user revokes access.
4. Claims: `iss` is `https://accounts.google.com`, `sub` is stable across sign-ins, `email_verified` is `true`, and the forwarded headers contain them.
5. Secrets: client secret and cookie secret only as mounted files, never in images, logs, Git or Compose interpolation; rotate the client secret after the test if it was ever exposed.
6. Cookie: `Secure`, `HttpOnly`, `SameSite=Lax`, host-only over HTTPS; sign-out clears it.
