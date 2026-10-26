# Browser authentication

## Deployment setup

For local development, run:

```sh
mise run generate-docker-compose
docker compose up -d --wait
```

The development generation task declares mise dependencies that create the external development network and missing private account/search/OAuth files, preserving existing files. The renderer itself only generates configuration. The `prepare` mode also runs these dependencies when it skips rendering existing configuration. `mise run dev-up` is a convenience shortcut for generation followed by Compose startup; it does not tear down the stack. OAuth2 Proxy runs with the generating user's UID/GID in development so it can read the owner-only secret files. The generated OAuth client secret is only a placeholder and the cookie secret is random; anonymous and configured bearer-token access do not require Google credentials. Development uses Google's explicit OIDC endpoints without startup discovery, so Google is contacted only when sign-in is used. Real Google sign-in still requires a registered client ID and client secret. Production retains OIDC discovery and explicit external secret-file requirements. Use the separate `generate-docker-compose-prod` task for production rendering without development dependencies; this temporary CI task will be removed when production moves to ARM64 k3d.

Docker may have created empty directories at missing secret-file paths during an earlier startup. Development provisioning removes only those empty default directories before creating files; nonempty directories, empty files, and invalid explicit secret-file overrides fail rather than being overwritten.

The generated auth-ingress network allocates dynamic addresses from the half of `AUTH_INGRESS_SUBNET` that does not contain `GRAPHQL_TRUSTED_INGRESS_IP` (defaults: `10.231.65.128/25` and `10.231.65.2`). This keeps NATS and other services from claiming Traefik's fixed address. To reset development containers and Compose-managed networks, run `docker compose down --remove-orphans`, then generate and start again. Data volumes are retained unless explicitly removed.

The generated Compose stack uses OAuth2 Proxy v7.15.5 with its OIDC provider, Traefik ForwardAuth, and Redis-backed sessions. OAuth2 Proxy is configured for the Google issuer `https://accounts.google.com`, the `openid email` scopes, and PKCE S256. Callback state and nonce validation are enabled; unverified email is not accepted by the proxy. The proxy does not maintain an account allowlist: GraphQL's mounted `/run/secrets/auth-accounts.json` remains the sole source of application roles.

Register a Google Web OAuth client with the exact redirect URI `https://<public-host>/oauth2/callback`. Supply its client ID while generating the production configuration; the generated `oauth2-proxy-alpha.yml` contains the public client ID, not a credential:

```sh
GOOGLE_OAUTH_CLIENT_ID='<client-id>' mise run generate-docker-compose-prod
```

Provide `GOOGLE_OAUTH_REDIRECT_URL` as that exact HTTPS callback URL and `GOOGLE_OAUTH_REDIRECT_HOST` as its exact host (without scheme or path) when starting Compose. The host is the only post-login return domain; do not use wildcards. Mount the OAuth client secret and OAuth2 Proxy cookie secret from private files by setting `GOOGLE_OAUTH_CLIENT_SECRET_FILE` and `OAUTH2_COOKIE_SECRET_FILE` to their paths. Compose mounts these files as secrets; their contents must never be placed in source, image build arguments, environment variables, or generated configuration. Keep the files outside the repository with owner-only permissions. The development defaults are `.secrets/google-oauth-client-secret` and `.secrets/oauth2-cookie-secret`; development can use HTTP and disables Secure cookies by default. Production always sets Secure cookies and requires the HTTPS callback URL and explicit secret-file paths. Do not activate production auth until HTTPS is terminated by the deployment ingress.

CI uses the same mise-generated development files rather than generating separate secrets. Only production image-validation/build steps explicitly select those files to satisfy production Compose's required secret paths; they are not deployment credentials.

The client-secret file must contain only the provider secret with no trailing newline. The cookie secret must use URL-safe base64 without a trailing newline; ordinary base64 containing `+` or `/` is not accepted by OAuth2 Proxy. Generate the cookie secret without displaying it, for example:

```sh
mkdir -p .secrets
umask 077
openssl rand -base64 32 | tr '+/' '-_' | tr -d '\n=' > .secrets/oauth2-cookie-secret
```

Regenerate Compose and the alpha configuration whenever the OAuth client ID changes. Do not edit generated `docker-compose.yml`, `traefik.yml`, or `oauth2-proxy-alpha.yml` directly. The generated stack has no public Redis, OAuth2 Proxy admin, or `/oauth2/auth` route. Only the explicit `/oauth2/start`, `/oauth2/callback`, `/oauth2/sign_in`, and `/oauth2/sign_out` paths are routed to OAuth2 Proxy; sign-in is navigation initiated by the UI, never a blanket redirect for data requests.

## Request and identity contract

Requests use one GraphQL endpoint and are classified in this order:

1. Any presented `Authorization` header, including an empty value, selects the bearer router ahead of any session cookie. It reaches GraphQL directly, without ForwardAuth or browser identity headers. GraphQL validates bearer credentials; malformed, empty, duplicate, and unknown credentials are rejected there and never fall back to a cookie or the credential-free role.
2. With no `Authorization` header, a cookie named `_oauth2_proxy` or a numbered chunk (`_oauth2_proxy_0`, etc.) selects strict ForwardAuth. The proxy receives only `Cookie` and `Authorization`, and Traefik copies only `X-Auth-Request-User`, `X-Auth-Request-Issuer`, `X-Auth-Request-Email`, and `X-Auth-Request-Email-Verified` to GraphQL. Refresh and clearing cookies are relayed through `Set-Cookie`.
3. With neither credential, the public GraphQL router does not call ForwardAuth. GraphQL applies the configured credential-free role, including when OAuth2 Proxy or Redis is unavailable.

Traefik strips trusted-identity headers and common aliases on both entrypoints before routing. Its `aliasHeadersStrategy=delete` setting also removes underscore/dot header aliases. The credential router has higher priority than the cookie router, so cookie-plus-bearer requests use bearer identity only. OAuth2 Proxy/Traefik rejections preserve their upstream status and body: for example, the PoC observed Redis failure as 401 and an OAuth2 Proxy outage as 500. Status alone does not distinguish invalid credentials from dependency failure. Do not normalize these responses to anonymous success or automatically replay a mutation after sign-in; show an explicit sign-in/retry action instead.

Production GraphQL is attached only to the private auth-ingress network and checks that `/graphql` connections originate from Traefik's fixed address `10.231.65.2`; direct requests receive 403. The development container remains reachable through the documented development network for tooling. OAuth2 Proxy and Redis have no published ports. Redis is on a private session network; OAuth2 Proxy alone also joins an unpublished egress network so it can reach the configured OIDC issuer.

For a private SSR caller, forward only the configured `_oauth2_proxy` cookie (including its numbered chunks) to `http://traefik/graphql`; do not forward client identity headers or an Authorization header. Traefik reauthenticates the cookie and GraphQL receives the same four trusted claims. Relay every upstream `Set-Cookie` header to the browser so refreshed and cleared chunks are retained. The shared public shell must remain independent of credentials and cacheable. Cookie forwarding does not make SSR actions or GraphQL multipart uploads CSRF-safe: mutation CSRF protection is a separate requirement. Never replay a mutation automatically after authentication.

## Session lifecycle and verification status

Cookie expiry is 168 hours with refresh every 50 minutes, using OAuth2 Proxy's sliding session behavior; there is no custom absolute-login deadline or step-up requirement. Redis uses append-only persistence with `appendfsync always` on a named volume. A Redis restart can recover sessions from that volume. Deleting the volume or losing its data invalidates server-side tickets and requires users to sign in again. Rotating the cookie secret invalidates existing browser sessions. Rotating the provider client secret requires updating the mounted file and restarting OAuth2 Proxy.

GraphQL evaluates the current configured roles for each request from its startup-loaded account map. After changing account roles or revoking an email, restart GraphQL; existing OAuth sessions then receive the new role decision on their next request. A successful provider refresh may update the verified email. If a refresh returns an unverified email, OAuth2 Proxy can retain the previous validated claims until the current token expires; this accepted library limitation is not repaired with custom refresh logic.

The deterministic mock-issuer experiment is documented in the [#64 PoC results](https://github.com/dhhyi/recipe-db/blob/50b522d/auth-poc/RESULTS.md) and its [reproducible harness](https://github.com/dhhyi/recipe-db/blob/50b522d/auth-poc/POC.md). That disposable harness is separate from this generated production config and does not prove application integration. These configuration tests and the PoC do not verify Google registration, real Google refresh-token issuance/refresh behavior, public HTTPS, production cookies, or ARM64 runtime behavior. Those remain separate deployment verification gates. The mock issuer must be test-only and must never replace the configured Google issuer in production.
