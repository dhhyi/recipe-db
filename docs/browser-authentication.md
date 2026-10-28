# Browser authentication

## Deployment setup

For local development, run:

```sh
mise run generate-docker-compose
docker compose up -d --wait
```

The development generation task declares mise dependencies that create the external development network and missing private account/search/OAuth/ingress files, preserving existing files. The renderer itself only generates configuration; provisioning runs even when Mise can reuse fresh generated files. `mise run dev-up` is a convenience shortcut for generation followed by Compose startup; it does not tear down the stack. OAuth2 Proxy runs with the generating user's UID/GID in development so it can read the owner-only secret files. The generated OAuth client secret is only a placeholder; the cookie and ingress secrets are independent random values. Anonymous and configured bearer-token access do not require Google credentials. Development uses Google's explicit OIDC endpoints without startup discovery, so Google is contacted only when sign-in is used. Real Google sign-in still requires a registered client ID and client secret. Production is deployed separately through the Kubernetes configuration; there is no production Compose renderer.

Docker may have created empty directories at missing secret-file paths during an earlier startup. Development provisioning removes only those empty default directories before creating files; nonempty directories, empty files, and invalid explicit secret-file overrides fail rather than being overwritten.

Docker allocates the private ingress networks and container addresses automatically; there are no fixed IPs or subnet overrides. When migrating from the fixed-IP configuration, first run `docker compose down --remove-orphans` using the old configuration, then regenerate and start the stack to recreate its networks. Data volumes are retained unless explicitly removed.

The generated Compose stack uses OAuth2 Proxy v7.15.5 with its OIDC provider, Traefik ForwardAuth, and Redis-backed sessions. OAuth2 Proxy is configured for the Google issuer `https://accounts.google.com`, the `openid email` scopes, and PKCE S256. Callback state and nonce validation are enabled; unverified email is not accepted by the proxy. The proxy does not maintain an account allowlist: GraphQL's mounted `/run/secrets/auth-accounts.json` remains the sole source of application roles.

Register a Google Web OAuth client with the exact redirect URI `https://<public-host>/oauth2/callback`. For development, provide its public client ID while generating Compose; `oauth2-proxy-alpha.yml` contains the ID, not a credential:

```sh
GOOGLE_OAUTH_CLIENT_ID='<client-id>' mise run generate-docker-compose
```

The development redirect defaults to `http://localhost:8080/oauth2/callback`; `GOOGLE_OAUTH_REDIRECT_URL`, `GOOGLE_OAUTH_REDIRECT_HOST`, and `OAUTH2_COOKIE_SECURE` remain Compose-time substitutions. Mount the OAuth client secret and OAuth2 Proxy cookie secret from private files using `GOOGLE_OAUTH_CLIENT_SECRET_FILE` and `OAUTH2_COOKIE_SECRET_FILE`. Compose mounts these files as secrets; their contents must never be placed in source, image build arguments, environment variables, or generated configuration. Keep the files outside the repository with owner-only permissions. The development defaults are `.secrets/google-oauth-client-secret` and `.secrets/oauth2-cookie-secret`; development can use HTTP and disables Secure cookies by default. Production settings, including the public client ID and deployment secret paths, belong in the Kubernetes deployment configuration described in [Production Kubernetes](production-kubernetes.md).

CI development-stack checks use the same Mise-generated development files rather than generating separate secrets. Production image publication uses the production build metadata and does not require the development Compose renderer or its secret provisioning.

Production ingress requires a private 43-character URL-safe secret. Set `secrets.graphql-ingress-secret` in the deployment values to the absolute path of that file; the Kubernetes deployment provisions it as a Secret shared only with Traefik and GraphQL. Use a separate private file for each production deployment, not the development or CI fixture. `mise run create-oauth-secrets` creates the ignored local `.secrets/graphql-ingress-secret` with 32 random bytes, mode 600, without replacing an existing file; `GRAPHQL_INGRESS_SECRET_FILE` can override that helper's output path. Production components reject malformed secrets at startup. An optional trailing LF is accepted.

The production Kubernetes deployment stores the ingress secret in a Kubernetes Secret and gives it only to Traefik and GraphQL. The secret is not embedded in Docker labels, generated repository configuration, container environment variables, or image layers. Do not enable debug logging or expose Traefik's configuration API: middleware/raw-data/support-dump endpoints can disclose the value. Production exposes only the two internal router/service list endpoints used by GraphQL's readiness queries, not the dashboard or full configuration API. Development does not mount or inject this token and retains its existing dashboard.

To rotate the ingress secret, update its private file and redeploy/restart Traefik and GraphQL together so their mounted and startup-loaded values agree. Requests fail with 403 while the values differ; there is no fallback to IP trust. The token is a replayable internal bearer credential: keep the deployment networks trusted and use authenticated encryption if proxy-to-GraphQL traffic crosses an untrusted network.

The client-secret file must contain only the provider secret with no trailing newline. The cookie secret must use URL-safe base64 without a trailing newline; ordinary base64 containing `+` or `/` is not accepted by OAuth2 Proxy. Generate the cookie secret without displaying it, for example:

```sh
mkdir -p .secrets
umask 077
openssl rand -base64 32 | tr '+/' '-_' | tr -d '\n=' > .secrets/oauth2-cookie-secret
```

Regenerate the development Compose and alpha configuration whenever the development OAuth client ID changes. Do not edit generated `docker-compose.yml` or `oauth2-proxy-alpha.yml` directly; production routes are rendered from the deployment template. The development stack has no public Redis, OAuth2 Proxy admin, or `/oauth2/auth` route. Only the explicit `/oauth2/start`, `/oauth2/callback`, `/oauth2/sign_in`, and `/oauth2/sign_out` paths are routed to OAuth2 Proxy; sign-in is navigation initiated by the UI, never a blanket redirect for data requests.

## Request and identity contract

Requests use one GraphQL endpoint and are classified in this order:

1. Any presented `Authorization` header, including an empty value, selects the bearer router ahead of any session cookie. It reaches GraphQL directly, without ForwardAuth or browser identity headers. GraphQL validates bearer credentials; malformed, empty, duplicate, and unknown credentials are rejected there and never fall back to a cookie or the credential-free role.
2. With no `Authorization` header, a cookie named `_oauth2_proxy` or a numbered chunk (`_oauth2_proxy_0`, etc.) selects strict ForwardAuth. The proxy receives only `Cookie` and `Authorization`, and Traefik copies only `X-Auth-Request-User`, `X-Auth-Request-Issuer`, `X-Auth-Request-Email`, and `X-Auth-Request-Email-Verified` to GraphQL. Refresh and clearing cookies are relayed through `Set-Cookie`.
3. With neither credential, the public GraphQL router does not call ForwardAuth. GraphQL applies the configured credential-free role, including when OAuth2 Proxy or Redis is unavailable.

Traefik strips trusted-identity headers and common aliases on both entrypoints before routing. Its `aliasHeadersStrategy=delete` setting also removes underscore/dot header aliases. The credential router has higher priority than the cookie router, so cookie-plus-bearer requests use bearer identity only. OAuth2 Proxy/Traefik rejections preserve their upstream status and body: for example, the PoC observed Redis failure as 401 and an OAuth2 Proxy outage as 500. Status alone does not distinguish invalid credentials from dependency failure. Do not normalize these responses to anonymous success or automatically replay a mutation after sign-in; show an explicit sign-in/retry action instead.

Production GraphQL is attached only to the private auth-ingress network. Traefik removes client-supplied `X-Internal-Ingress-Token` headers on both entrypoints and injects the deployment secret only on GraphQL routes, after ForwardAuth when applicable. GraphQL requires exactly one matching header using a constant-time comparison, returns 403 for missing/invalid/duplicate values, and removes it before invoking application handlers. Possession of this secret, not a source IP, establishes ingress trust. Health endpoints remain available without it. Development does not enforce the ingress token and remains reachable through the documented development network for tooling.

OAuth2 Proxy and Redis have no published ports. A separate private oauth2-ingress network connects only Traefik and OAuth2 Proxy, replacing the proxy's old fixed-IP forwarded-header allowlist with network isolation; do not attach other callers to that network. Redis is on a private session network; OAuth2 Proxy alone also joins an unpublished egress network so it can reach the configured OIDC issuer. The ingress token is never sent to OAuth2 Proxy, Redis, other application services, or browsers.

For a private browse fragment or rating action, forward only the request's bearer `Authorization` header, or only the configured `_oauth2_proxy` cookie chunks if no bearer header is present, to `http://traefik/graphql`; do not forward client identity headers. Traefik reauthenticates the cookie and GraphQL receives the same four trusted claims. Relay every upstream `Set-Cookie` header to the browser so refreshed and cleared chunks are retained. Public-shell cache fills use a separate credential-free client and never inspect or forward browser credentials. Browse never uses a shared owner credential.

Browse loads `/identity` separately into the header component. Its `auth-role` attribute selects a single right-aligned action: `anonymous` shows login; other roles show logout with the role as a tooltip. Omitting `auth-role` renders a plain header without authentication controls, as used by the editor pages. An identity lookup failure uses `auth-unavailable` to show an explicit status instead of guessing an action.

Browser writes are protected at both browse and GraphQL. Browse rating POSTs require exactly one same-origin `Origin` matching the request host and Traefik-provided `X-Forwarded-Proto`; missing, duplicate, malformed, or foreign origins fail before GraphQL is called. GraphQL applies the same origin check to mutations (including multipart uploads), rejects mutation-over-GET, and returns a structured `csrf-forbidden` error. Non-browser bearer clients remain supported without an `Origin` header; if they provide an Origin, it must match. In production, the GraphQL ingress token ensures GraphQL receives these forwarded-protocol headers only through the trusted Traefik boundary, and deployment networks must prevent direct GraphQL access. Do not trust `X-Forwarded-Host`; origin validation compares against the request `Host`. SameSite cookies remain defense in depth, not the CSRF control. Never replay a mutation automatically after authentication.

## Local credential-free and token identities

The account configuration is authoritative in both environments. In development, choose the credential-free role by editing `.secrets/auth-accounts.json` and setting `anonymous.role` to `anonymous`, `member`, or `owner`, then restart GraphQL with `docker compose restart graphql`. Production uses the account file referenced by its Kubernetes deployment values and must be redeployed after a change. The file is read only at startup; changing it does not hot-reload policy. All credential-free requests share the stable `credential-free:v1` identity, so separate-user tests need distinct configured token IDs.

For isolated E2E auth tests, `mise run create-auth-test-fixture` creates deterministic IDs (`e2e-owner`, `e2e-member-one`, `e2e-member-two`) with fresh random secrets in the same `.secrets/auth-accounts.json` mounted at `/run/secrets/auth-accounts.json`. It writes the client-only token inputs to `e2e-test/.secrets/auth-tokens.json`; both files are private and ignored by Git. This fixture is generated automatically by `mise run setup`, `mise run generate-docker-compose`, and the corresponding CI setup. Repeated setup preserves the generated token values, the selected `anonymous.role`, and unrelated configured principals. Compose integration tests pass the token inputs only to the E2E test process; GraphQL still reads its policy solely from `/run/secrets/auth-accounts.json`. Restart GraphQL after generation:

```sh
mise run create-auth-test-fixture
docker compose restart graphql
mise run --raw in-devcontainer e2e-test pnpm exec playwright test tests/auth-contexts.functional.spec.js --project=desktop
```

Start the development Compose stack first (`mise run dev-up`). The focused test exercises anonymous, both member, and owner request headers, isolated browser/API cookies, and same-origin-only credential forwarding across external requests and redirects. It uses no Google credentials or Google network access. The generated fixture initially keeps `anonymous.role` at `anonymous`; application E2E setup and default editor flows use the isolated owner token, while public-browser and permission tests use explicit anonymous or member contexts.

The visual suite uses explicit anonymous, member, and owner contexts for the overview, recipe detail, full-page error, existing/new recipe editors, and image editor. Non-owners capture the editors' authentication-required or forbidden views; the open crop-editor state is owner-only. Each role inherits the configured mobile, landscape, dark-tablet, and desktop browser settings. Detail fixtures include distinct owner/member votes to cover the personal overlay against the public average. Run `mise run --raw in-devcontainer e2e-test pnpm test pages.visual.spec.js` to compare screenshots, or append `--update-snapshots` to regenerate baselines. These tests reset application data and require `anonymous.role` to be `anonymous` in the active account policy, so use the development test stack.

To restore the standard local fixture after a successful generation, remove only the generated files, recreate the default policy, and restart GraphQL:

```sh
rm -f .secrets/auth-accounts.json e2e-test/.secrets/auth-tokens.json
rmdir e2e-test/.secrets 2> /dev/null || true
mise run --raw create-auth-accounts
docker compose restart graphql
```

Do not remove the whole `.secrets` directory or tear down Compose as part of this cleanup; unrelated local secrets and existing services are not owned by the E2E fixture. A token-capable API client or browser header tool can also send a `Bearer` header containing a chosen fixture token to the application origin for simultaneous identities. Keep headers scoped to that origin. Removing a static token header selects credential-free access; it is not OAuth session logout or server-side token revocation. No sign-in/out feature or browser identity picker is provided by this workflow.

## MCP configured-token access

MCP uses stateless Streamable HTTP at `/mcp`, not legacy SSE or a login session. Each request forwards only its own bearer `Authorization` header to GraphQL through Traefik, including schema/online-service queries, ratings and multipart image uploads. Browser cookies and caller-supplied identity headers are not forwarded. Cookie-only requests remain credential-free; bearer plus cookies uses only the bearer. Invalid presented credentials fail explicitly rather than selecting the credential-free role. The server-to-server GraphQL request sets its Origin to the fixed GraphQL destination, never the incoming browser Origin, so GraphQL's CSRF gate does not override intentionally privileged credential-free roles. GraphQL errors become MCP tool results with `isError: true` and the available stable code/message; mutations are not automatically retried. External image downloads, including redirects, use a separate credential-free client.

The server has no MCP-specific token file or environment variable. GraphQL reads only its read-only mounted `/run/secrets/auth-accounts.json` at startup in Compose and Kubernetes. Its configuration contains `anonymous: {role, displayName?}`, `tokens: [{id, secret, role, displayName?}]`, and `googleAccounts: {email: role}`. Tokens represent stable namespaced token IDs, not Google accounts. Keep an ID when rotating its secret to preserve attribution. Restart GraphQL after changing secrets, removing tokens or changing roles. Configuration is authoritative, including an intentionally privileged `anonymous.role`; MCP does not impose a separate role policy. Members may rate, owners may manage recipes/images, and no tool accepts a rating author, login or role as authority.

For the portable Copilot configuration, merge this entry into `$COPILOT_HOME/mcp-config.json` (default `~/.copilot/mcp-config.json`), outside the repository. The [VS Code configuration reference](https://code.visualstudio.com/docs/agents/reference/mcp-configuration) documents portable header environment references. Use HTTPS for a remote deployment:

```json
{
  "mcpServers": {
    "recipe-db-mcp": {
      "type": "http",
      "url": "http://localhost:8080/mcp",
      "headers": {
        "Authorization": "\u0042earer ${RECIPE_DB_MCP_TOKEN}"
      },
      "tools": ["*"]
    }
  }
}
```

Provide `RECIPE_DB_MCP_TOKEN` to the process launching the client, not the server. For example, in a Bash terminal, read it without echo or shell-history exposure, then launch a fresh VS Code process from that terminal:

```sh
read -r -s -p 'Recipe DB MCP token: ' RECIPE_DB_MCP_TOKEN
printf '\n'
export RECIPE_DB_MCP_TOKEN
code
unset RECIPE_DB_MCP_TOKEN
```

Fully quit an already-running VS Code instance first so it does not reuse an older process environment. For a separately launched Copilot harness, supply the variable to that harness process too. Do not put the value in workspace settings, `.mcp.json`, shell startup files, command-line arguments, tool arguments, logs or chat. Environment variables are client-side credential delivery, not a server configuration alternative.

The JSON escape `\u0042` is the letter `B`; the decoded header uses the standard bearer scheme. For VS Code-managed HTTP MCP configuration, replace `${RECIPE_DB_MCP_TOKEN}` with `${env:RECIPE_DB_MCP_TOKEN}` and use its user-level `servers` entry. The portable `mcpServers` configuration above is for the Copilot harness; these file formats and variable syntaxes are not interchangeable. The repository's credential-free `.mcp.json` is intentionally unchanged. To use public reads, omit the header entirely rather than sending an empty or unresolved token reference.

Client verification must connect using the user-level configuration and run an anonymous `list_recipes`/`get_recipe_schema`, an owner `add_recipe`, and a denied anonymous or member write, checking `isError: true`. Also verify member ratings without an author argument. The Python MCP integration suite tests the HTTP behavior but does **not** establish Copilot harness or VS Code compatibility. No real Copilot harness/VS Code connection has been verified in this environment; that acceptance gate remains open. VS Code password-masked `${input:...}` configuration is unsupported/unverified here; no interactive OAuth or token issuance UI is provided.

## Session lifecycle and verification status

Run `mise run test-auth-ingress` to render the production routing template directly and exercise it with real Traefik and an isolated mock HTTP backend (Docker and the `traefik:v3.7` / `python:3.13-slim` images are required). It verifies token overwrite, identity sanitization, cookie/bearer precedence, invalid-cookie rejection, and blocked configuration API endpoints without Google credentials. This is an ingress transport test, not an OIDC login test. GraphQL's token validation and health-route exemption are covered by its Rust tests.

Cookie expiry is 168 hours with refresh every 50 minutes, using OAuth2 Proxy's sliding session behavior; there is no custom absolute-login deadline or step-up requirement. Redis uses append-only persistence with `appendfsync always` on a named volume. A Redis restart can recover sessions from that volume. Deleting the volume or losing its data invalidates server-side tickets and requires users to sign in again. Rotating the cookie secret invalidates existing browser sessions. Rotating the provider client secret requires updating the mounted file and restarting OAuth2 Proxy.

GraphQL evaluates the current configured roles for each request from its startup-loaded account map. After changing account roles or revoking an email, restart GraphQL; existing OAuth sessions then receive the new role decision on their next request. A successful provider refresh may update the verified email. If a refresh returns an unverified email, OAuth2 Proxy can retain the previous validated claims until the current token expires; this accepted library limitation is not repaired with custom refresh logic.

The deterministic mock-issuer experiment is documented in the [#64 PoC results](https://github.com/dhhyi/recipe-db/blob/50b522d/auth-poc/RESULTS.md) and its [reproducible harness](https://github.com/dhhyi/recipe-db/blob/50b522d/auth-poc/POC.md). That disposable harness is separate from the deployed production Kubernetes configuration and does not prove application integration. These configuration tests and the PoC do not verify Google registration, real Google refresh-token issuance/refresh behavior, public HTTPS, production cookies, or ARM64 runtime behavior. Those remain separate deployment verification gates. The mock issuer must be test-only and must never replace the configured Google issuer in production.
