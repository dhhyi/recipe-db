# Access-model verification

Evidence consolidated on 2026-11-05 for [#52: Verify and document the complete access model](https://github.com/dhhyi/recipe-db/issues/52). This is an evidence handoff, not a new test run or final go-live approval. Reuse completed component checks and operator observations; repeat a check only when a changed implementation or a concrete evidence gap requires it.

## Permission contract

GraphQL is the permission authority for the website, MCP and API clients. Authorization follows the effective configured role, not the login mechanism.

| Operation | Anonymous | Member | Owner |
| --- | --- | --- | --- |
| Public recipes, metadata, images, inspirations, search and rating aggregates | Allow | Allow | Allow |
| Own rating lookup and submission/update | Deny | Allow | Allow |
| Recipe, import, inspiration and image management | Deny | Deny | Allow |
| Owner-gated test reset mutations | Deny | Deny | Only where the runtime permits |

Testing-only service-availability controls have their separate documented contract; they are not a grant of management permissions or public reset access. Backend reset and maintenance APIs remain private and mode-restricted.

The startup-loaded, read-only `/run/secrets/auth-accounts.json` is the sole server-side policy source. Credential-free member/owner roles are supported deliberately; all credential-free callers share one identity. Token IDs and Google issuer/subject identify voters independently of role, display name or email. No voter directory, caller-selected rating author or Google-bound MCP token is part of this model.

## Evidence sources and tested configurations

| Source | Evidence and limits |
| --- | --- |
| [Application enforcement implementation](https://github.com/dhhyi/recipe-db/pull/80), merged as `b9aae7c` | Reported passing ratings integration (21 scenarios), authenticated GraphQL (31), search (11), two-member browser ratings including absent-vote null, auth-context E2E, three real-Traefik ingress tests, project checks and CodeQL (zero alerts). Its historical MCP write failures were explicitly handed to the later MCP implementation, not counted as passes here. |
| [MCP implementation](https://github.com/dhhyi/recipe-db/pull/88), merged as `3b8bf96` | Adds request-local token forwarding and permission/concurrency/upload regressions. [Existing quality checks](https://github.com/dhhyi/recipe-db/actions/runs/40771991077/job/123111316761) and ARM64 validation succeeded. The inspected quality log includes MCP source checks, not a live pytest result; do not infer a live MCP scenario count from that job. The operator reports existing automated MCP permission verification; no duplicate suite was run for this documentation. Real Copilot/VS Code setup is explicitly unverified in the merged implementation. |
| [Physical Pi deployment evidence](https://github.com/dhhyi/recipe-db/issues/45) | Actual ARM64 Pi runtime evidence belongs here, separately from image manifests or cross-platform build checks. The current Google browser observations below were made against the physical Pi. |
| [HTTPS/network and credential evidence](https://github.com/dhhyi/recipe-db/issues/44) | Existing trusted HTTPS/isolation and rotation evidence includes rejection of both old bearer secrets, retained-principal vote continuity and subsequent removal of revoked credential copies. These are historical verified checks, not new probes. |
| [Real Google verification](https://github.com/dhhyi/recipe-db/issues/68) | Operator-guided local HTTP and Pi HTTPS browser checks on 2026-11-05, with Chrome 156.0.8078.80 (Official Build), 64-bit. Provider refresh/revocation remain incomplete as detailed below. |

The configuration and evidence changes were merged in [#170: Support Google sign-in on Pi deployments](https://github.com/dhhyi/recipe-db/pull/170), merge revision `a1ecd5071a74683a9ea0518995d1939b96f4b1d4`. They include `063117a` (offline consent), `408cf9d` (rendered-configuration rollout), and `3716b23` (approved lifecycle evidence); their normal pre-commit validation passed. This merge is source provenance, not a new deployment or test run.

The tested Pi application images remain the existing immutable release `ghcr.io/dhhyi/recipe-db-releases@sha256:72e8b262a6308b35f0fb3df0125caf0027468c6b14436871a2db5e29c74f125f`, revision `dd5f3a4172b6b7639d6d9ad8e55b5c0e293c7a7f`, deployed with the newer configuration/templates. Do not describe the merged source revision as deployed application images. Local Compose and Pi Kubernetes are distinct topologies.

| Platform | Actual evidence |
| --- | --- |
| Local amd64 | The running Docker engine reports `linux/x86_64`; local Compose real-Google browser/session checks below ran against this engine. This is not a new full integration-suite run or a claim that every image architecture was independently inspected. |
| Physical Pi ARM64 | Physical deployment/runtime evidence is owned by the closed [#45: Set up the physical Raspberry Pi and validate deployment operations](https://github.com/dhhyi/recipe-db/issues/45). Real Google HTTPS browser/session and proxy-log checks below were performed against that Pi, not inferred from a multi-platform manifest. No duplicate hardware test was run for reconciliation. |

## Coverage map

Existing automated coverage is located below. Presence of a regression is not, by itself, a claim that it was run again on this documentation revision.

| Requirement | Reusable implementation/test evidence |
| --- | --- |
| Effective-role matrix, invalid credentials without fallback, Google claim validation, privileged credential-free roles | [GraphQL auth tests](../graphql/src/auth.rs), including unknown/unverified identities and capabilities for every principal source |
| Stable Google identity despite email changes; token rotation retaining identity; policy reload | GraphQL auth tests for issuer/subject identity, token-secret rotation and changed-policy contexts; historical deployment rotation evidence |
| Trusted ingress, forged identity stripping and bearer precedence | [Ingress regression](../.scripts/tests/traefik-ingress.bats), [GraphQL HTTP tests](../graphql/src/main.rs), application implementation's real-Traefik results; Pi genuine-cookie plus invalid-bearer browser probe |
| Browser writes, same-origin checks, mutation-over-GET | GraphQL HTTP tests and [browse request tests](../browse/request_test.go); application implementation's browser-write contract |
| Request-scoped forwarding and cookie relay | Browse request transport tests; bearer-or-cookie forwarding only, renewal/clearing cookie propagation |
| Independent votes, repeated updates, absent-vote null, aggregates | [GraphQL ratings integration](../graphql-test/ratings.feature), [integration scenarios](../graphql-test/integration.feature), [two-member browser scenario](../e2e-test/tests/recipes.functional.spec.js); passing counts reported by the application implementation |
| MCP anonymous/denied writes, current bearer after initialize, malformed credentials, cookies and concurrent identities | [MCP auth integration tests](../mcp-test/test_auth.py); explicit denied-write side-effect and independent-vote assertions |
| MCP multipart and external redirect credential isolation | MCP auth integration upload/redirect regression; separate credential-free external download client |
| Shared HTML versus personal fragments, public metadata, editor denials and visual roles | [Browser auth contract](browser-authentication.md), [auth contexts](../e2e-test/tests/auth-contexts.functional.spec.js), [role visual scenarios](../e2e-test/tests/pages.visual.spec.js) and browser rating scenarios. This session refreshed 164 baselines and reported all 116 visual tests passing twice before live Google verification. Baselines assume Google is absent. |
| Backend/admin isolation and optional Google routing | [Kubernetes regressions](../.scripts/tests/kubernetes-templates.bats), [deployment regressions](../.scripts/tests/production-k3d.bats), live Pi private OAuth/admin 404 probes and trusted HTTPS 200 checks |
| Runtime restrictions | Current service/runtime contracts and tests remain authoritative; access roles do not enable production reset routes |

Mixed public/private GraphQL response shapes, browser history isolation, public-only search indexing and auth-service/Redis outage behavior remain requirements of the existing contract. The sources above must not be interpreted as a new, individually witnessed pass for every one of those cases. Where an exact result is needed for final acceptance, recover the original component evidence first rather than repeat the whole stack or mark a source check as a runtime test.

## Operator-confirmed browser results

The following observations are recorded in the real-provider issue:

- Local and Pi real Google login, logout, owner recognition, anonymous browsing and direct anonymous editor denial.
- Local and Pi member rating persistence with management controls absent and direct editor access denied. Owner permissions restored afterward.
- Existing Pi sessions lose privileges after role removal and regain them after restoration/restart without another login.
- A new Pi Google login while the account is temporarily unmapped remains read-only. Authentication-success logs corroborate login. The login button can still appear for an authenticated account with anonymous effective role.
- Uppercase spelling of the Pi policy email preserves owner lookup; original spelling restored. This is not Gmail/googlemail alias equivalence.
- Personal ratings persist through logout and new Google login locally and on Pi: behavioral identity continuity, not inspection of raw subject values.
- A real Pi owner cookie alone resolves owner; adding an invalid bearer rejects authentication rather than falling back to that cookie.
- Actual session cookies: HttpOnly and SameSite=Lax on both; Secure on Pi HTTPS, not local HTTP.
- One isolated local Redis session was given a 30-second TTL. After expiry, owner/editor access was denied; re-login restored it. First reload displayed a blank header, second reload the login button. Existing sessions, recipe data and configured lifetimes were unchanged. This is not natural seven-day expiry.

## Access-model checklist reconciliation

The operator approved four additional completed criteria in [#52: Verify and document the complete access model](https://github.com/dhhyi/recipe-db/issues/52): Google lifecycle/setup documentation, durable configuration/version/topology/method evidence, explicit platform verification status, and incorporation of the completed real-provider record. At that reconciliation, the top-level checklist moved from 15 complete / 18 incomplete to 19 complete / 14 incomplete. The route and ingress verification below completed two more (21 complete / 12 incomplete); the actual MCP client verification completes another, bringing the current count to 22 complete / 11 incomplete. No criterion was removed, split to inflate completion, or waived.

### Route and ingress verification (2026-11-06)

The first two remaining cross-stack criteria are verified against the live Pi preview and current routing configuration. The route snapshot was read through the documented private workstation tunnel; the ingress-token value was not emitted. The deployed application revision remains `dd5f3a4172b6b7639d6d9ad8e55b5c0e293c7a7f`; this is deployed-release evidence, not a claim that the current source checkout is deployed.

| Check | Result |
| --- | --- |
| Caller wiring | Browse and MCP use `http://traefik/graphql`; production search uses `http://traefik:3000/graphql`. Its live `graphql-internal` router is on `rest-internal`, targets the internal GraphQL projection service and has the ingress-token middleware configured. Search, GraphQL, browse and MCP Deployments were ready; search's index-readiness sidecar was ready. |
| Browser/GraphQL/MCP live reads | HTTPS `GET /`, `GET /design/`, `GET /edit`, `GET /images`, full-page browse and an `HX-Request` browse request returned 200. Anonymous GraphQL returned role `anonymous` with no rate or management capabilities. The same query with forged Google identity headers returned the same anonymous capabilities. MCP initialize and anonymous `get_recipe_schema` returned success. No mutation was sent. |
| Public/private route boundary | The live route snapshot showed public web/websecure routes for the frontend, design, editor pages, public images, GraphQL, MCP and configured OAuth endpoints. Representative REST, Typesense/NATS and Traefik admin/configuration paths returned 404 over the public HTTPS route. Private REST/search/admin routers use `rest-internal`; the Traefik Service exposes web ports but not the internal port. `recipe-db-internal` is `ClusterIP`; application and infrastructure Services are `ClusterIP` except the in-namespace Traefik `ExternalName` alias. |
| Direct GraphQL guard and spoof stripping | The live route configuration shows the internal GraphQL router uses the ingress-token middleware. The live HelmChartConfig applies `identity-strip@file` to both `web` and `rest-internal` entrypoints with `aliasHeadersStrategy=delete`; the configured middleware strips identity and ingress-token headers. A real-Traefik Docker fixture passed all three scenarios; the GraphQL ingress unit test passed, including denial without a token and removal of the token before the handler. No live pod-port-forward bypass attempt was made. |

Validation: `mise run --raw test-auth-ingress` passed 3/3; `mise run --raw test-scripts compose` passed 10 tests and skipped its duplicate opt-in Docker ingress case; `mise run --raw in-devcontainer graphql cargo test ingress_guards_graphql_but_not_health_and_consumes_the_token` passed 1/1. The dedicated Kubernetes-template and production route-assembly Bazel targets succeeded from cache for current inputs; those actions were not rerun. No deployment, policy, credential or stored-data changes were made.

The tested deployment topology is the physical Pi Kubernetes preview, queried through its existing private workstation tunnel, plus HTTPS requests through its configured preview origin. These checks do not claim public-Internet reachability from every network or replace the separate operator/client acceptance in [#68 — Set up and verify real Google authentication before public go-live](https://github.com/dhhyi/recipe-db/issues/68) and [#52 — Verify and document the complete access model](https://github.com/dhhyi/recipe-db/issues/52). The observed Traefik Service was `LoadBalancer` with web port 80, staging HTTP 8081 and websecure 8443; `rest-internal` remains cluster-private. Router forwarding, firewall and provider setup remain deployment prerequisites owned by their existing issues.

### VS Code/Copilot MCP client verification (2026-11-06)

The operator started the real VS Code user-profile MCP servers against `https://rezept-db.freeddns.org/mcp`, confirmed successful anonymous reads, and disabled the conflicting localhost-bound server. The refreshed Copilot session then exposed the three profile servers and executed the checks below directly through their MCP tools. Installed client metadata reports VS Code `1.145.1`, build `6bab64e2d12b04d04c0d99c27ff166023efd1dda`, and bundled Copilot extension `0.73.0`. The server remained the existing Pi application release `dd5f3a4172b6b7639d6d9ad8e55b5c0e293c7a7f`; GraphQL's image was `ghcr.io/dhhyi/recipe-db-graphql@sha256:2b461ba9f88099f917506ea13a2187f7eac79a76c871aa708057c58b5b9e2636`.

The live policy initially had `anonymous.role: anonymous`, no bearer tokens and one Google account. With explicit operator approval, two random temporary owner/member tokens were added to that policy and GraphQL restarted. At the operator's request, their client headers were configured privately in the Windows user-profile file, outside the workspace, rather than relying on a newly launched process environment. Existing Google configuration and unrelated MCP servers were preserved. No credential values are part of this record.

| Actual client check | Result |
| --- | --- |
| Anonymous `get_recipe_schema` and `list_recipes` | Returned the live schema and six existing recipes. |
| Owner `add_recipe` | Created disposable recipe `f665f96a-8e8c-4b42-976e-12af71229a46`, named `MCP client verification 2026-11-06`. |
| Anonymous `add_recipe` | Failed explicitly with `authentication-required`, status 401. |
| Member `add_recipe` | Failed explicitly with `forbidden`, status 403. |
| Member `add_rating` | Arguments contained only `recipeId` and `rating: 4`; returned `average: 4`, `count: 1`. Member `get_recipe` confirmed that aggregate. |
| Anonymous `add_rating` | Failed with `authentication-required`, status 401; a subsequent member read still reported `average: 4`, `count: 1`. |
| Denied-create side effects | Anonymous listing showed only the original six recipes and the owner's disposable recipe, with neither denied-create name present. |
| Token revocation | After removing both temporary tokens and restarting GraphQL, owner `list_recipes` and member `get_recipe` both failed with `invalid-credentials`, status 401; anonymous listing returned the original six recipes. |

The client bridge surfaced the denied calls as tool errors. Supplementary raw Streamable HTTP `tools/call` probes confirmed `result.isError: true` for anonymous and member creates, with the same stable codes/statuses. These wire probes supplement, rather than replace, the actual client checks; their SSE `data:` frames were decoded before inspecting JSON.

Cleanup deleted the disposable recipe through trusted GraphQL ingress (`deleteRecipe: true`), removed only the two temporary principals from the current live policy, restarted GraphQL and removed the credential-bearing owner/member profile entries. Anonymous and unrelated GitHub profile entries remain. Private workspace credential copies and temporary policy/transport files were removed; no data-reset or backend-direct API was used. Immediately after the revocation rollout, the first read attempts returned transient 503s; subsequent reads established the stated revoked/anonymous behavior. This is not a full outage-recovery test.

The [verified client setup instructions](browser-authentication.md#verified-vs-code-user-profile-setup-2026-11-06) document the exact user-profile format and secret handling. This completes the real client setup/authorized-denied operation criterion, not the entire permission matrix or final operator acceptance. Environment-reference interpolation, a separate standalone Copilot client and masked-input support were not tested.

| Remaining criterion | Supported evidence and unresolved portion |
| --- | --- |
| Request-scoped forwarding, cookie relay and concurrent identity isolation | Transport regressions and successful browser refresh exist; reconcile combined browser/token/MCP concurrency and clearing/renewal coverage. |
| Public-only search indexing | Existing search tests exist; establish exact evidence that indexing never uses owner access or includes private data. |
| Entire client/role matrix and side-effect denials | Component and Google browser checks cover substantial behavior; reconcile all GraphQL/HTMX/editor/MCP operations and runtime reset restrictions. |
| Independent/repeated/concurrent votes and aggregates | Two-member and attribution/rotation results exist; recover exact concurrent-update and aggregate assertions/results. |
| Partial GraphQL responses and absent-vote null | Absent-vote behavior has evidence; reconcile mixed allowed/denied field shapes and structured errors. |
| Complete denied/expired/unapproved UX and recovery | Browser denials, expiry/re-login and revocation passed; reconcile public recovery/no-auto-replay evidence. First-reload blank header is explicitly accepted/deferred, not an unacknowledged failure. |
| Public shared HTML, no-store personal fragments and history isolation | Contract and component tests exist; reconcile sequential-user and ordinary/HTMX history isolation evidence. |
| Anonymous JavaScript-free recipe/schema.org markup | Preserve the stated markup-only requirement; establish exact evidence. No external Bring! experiment is required. |
| Full browser-write protection matrix | Existing origin/CSRF tests exist; reconcile cross-origin rating/GraphQL/multipart, privileged credential-free, same-origin and non-browser bearer coverage/results. |
| Complete integrated session lifecycle | Real Google login/logout, refresh, controlled expiry, revocation/recovery are approved; integrated mock-OIDC lifecycle and auth-service/Redis outage coverage remain unresolved. No natural seven-day test is claimed. |
| Final failed-check resolution and integrated acceptance | Resolve or explicitly agree treatment of the remaining gaps, then obtain this issue's separate operator acceptance. Approval of the Google record does not close this gate. |

## Remaining acceptance and known limitations

1. **Real provider lifecycle remains open.** Initial refresh failed on both origins because sessions lacked refresh tokens. Offline access and consent are now fixed in active login redirects, including rejection of weaker parameter overrides. This is not yet a successful full-duration refresh. Google connection removal was operator-confirmed around 18:41 CET; both sessions still had access around 18:43. Enforcement on subsequent refresh/expiry and reauthorization recovery remain pending. Do not reauthorize during that observation. Successful-refresh testing is last.
2. **Configured policy is not elapsed-time evidence.** Cookie lifetime is seven days sliding, refresh interval fifty minutes. No real seven-day observation is claimed. The umbrella also retains an unresolved integrated mock-OIDC lifecycle evidence gap from the browser-authentication implementation; its transport tests and the separate PoC do not establish full callback/refresh/logout coverage. Failed unverified-email refresh may preserve the previously validated identity until the current token expires; application-policy revocation after GraphQL restart is a separate verified mechanism.
3. **Real MCP client verification is complete for the recorded setup.** Actual VS Code/Copilot user-profile reads, authorized writes, denials and member ratings passed as recorded above. This does not verify environment interpolation, password prompts or a separate standalone client, and does not replace the full integrated permission matrix or operator acceptance.
4. **UX limitations are recorded, not hidden.** Expired-session first-load header fallback can be blank. An unapproved Google identity can still see the login button. Neither grants write permission. Browser recipe deletion is intentionally absent and is not an acceptance requirement.
5. **Final acceptance is manual.** Incorporate completed provider evidence, resolve any remaining evidence gaps and obtain operator approval before closing the access-model issue. The separate public-launch task remains gated; this document neither enables exposure nor approves go-live.

## Operating and recovery instructions

Use the existing [browser authentication guide](browser-authentication.md) for policy format, local fixtures, portable MCP environment-variable setup, strict client configuration formats, origin protection and cookie/session behavior. Use [production Kubernetes operations](production-kubernetes.md) for private secret delivery, guarded deployment, configuration-triggered rollouts and private route boundaries. No new README setup path or alternate policy source is introduced.

### Verified Google setup and evidence method

- The operator registered an External Google application in Testing, with separate Web clients for `http://localhost:8080/oauth2/callback` and `https://rezept-db.freeddns.org/oauth2/callback`. Google basic `openid email` sign-in uses the documented test-user-list exception; no broader consent/production approval or indefinite refresh-token validity is claimed.
- Local client/cookie secrets were delivered through private files and complete Google generation inputs; Pi inputs used private values and the Kubernetes secret mechanism. No secrets, account email, cookie, OAuth state/code or raw identity values belong in this record.
- Effective login requests used Google issuer `https://accounts.google.com`, `openid email`, PKCE S256 and fixed offline access/consent. Issuer/nonce and verified-email checks remained enabled. Anonymous browsing and bearer-first routing were unchanged.
- Read-only redirect checks inspected only HTTP status and allowlisted parameters, including attempted weaker overrides. Home/identity returned 200; checked private auth/admin paths returned 404. Actual session-cookie attributes are recorded above.
- The guarded deployment command shape was `KUBECONFIG=<private-file> mise run production-k3d deploy <private-values-file> <immutable-release-reference>`. Its release identity is recorded above; newer configuration is not a new app-image deployment.
- Proxy evidence was retrieved with `docker logs --since <window> oauth2-proxy` and `kubectl --kubeconfig=<private-file> --context=recipe-db-pi -n recipe-db logs deployment/oauth2-proxy --since=<window>`. Raw output was captured privately and reduced to fixed marker counts/timestamps. Do not paste unrestricted logs: they may contain identity/session data. A refused Pi connection required restoring the private API tunnel, not changing public ingress.
- Final browser checks preserved existing sessions beyond initial token lifetime, without logout, cookie clearing or new consent. A refresh-attempt log alone was insufficient: browser permission continuity, no-refresh/error/save markers and pinned proxy control flow were checked together.

- Role changes, token removal and rotation require GraphQL restart/replica rollout; editing the policy file alone is insufficient. Preserve token IDs when rotating secrets to preserve votes. Empty token/Google maps are valid.
- Keep secrets in private files/client process environments as documented, never in issue evidence, committed configuration or tool arguments. Browser Google identity is not an MCP credential; omit Authorization entirely for public MCP reads rather than send an empty token.
- Redis loss or cookie-key rotation requires browser login again. Provider client-secret changes require proxy restart. Template-only provider changes now trigger workload replacement via the rendered-manifest checksum.
- On denied or expired operations, return to public browsing or explicitly sign in; never replay a mutation automatically. Check outcome before retrying an interrupted write.
- Do not run destructive integration/E2E suites, regenerate Compose without its active Google inputs, restart authentication or sign in again during the ongoing revocation observation. Existing test commands in the guide are for an isolated testing stack, through the specified devcontainer runners.
