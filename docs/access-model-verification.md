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

The documentation branch includes `063117a` (offline consent) and `408cf9d` (rendered-configuration rollout). Both passed normal pre-commit validation. Pi application images remain the existing immutable release `ghcr.io/dhhyi/recipe-db-releases@sha256:72e8b262a6308b35f0fb3df0125caf0027468c6b14436871a2db5e29c74f125f`, revision `dd5f3a4172b6b7639d6d9ad8e55b5c0e293c7a7f`, deployed with the branch's newer configuration/templates. Do not describe the whole branch as deployed application images. Local Compose and Pi Kubernetes are distinct topologies.

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

## Remaining acceptance and known limitations

1. **Real provider lifecycle remains open.** Initial refresh failed on both origins because sessions lacked refresh tokens. Offline access and consent are now fixed in active login redirects, including rejection of weaker parameter overrides. This is not yet a successful full-duration refresh. Google connection removal was operator-confirmed around 18:41 CET; both sessions still had access around 18:43. Enforcement on subsequent refresh/expiry and reauthorization recovery remain pending. Do not reauthorize during that observation. Successful-refresh testing is last.
2. **Configured policy is not elapsed-time evidence.** Cookie lifetime is seven days sliding, refresh interval fifty minutes. No real seven-day observation is claimed. The umbrella also retains an unresolved integrated mock-OIDC lifecycle evidence gap from the browser-authentication implementation; its transport tests and the separate PoC do not establish full callback/refresh/logout coverage. Failed unverified-email refresh may preserve the previously validated identity until the current token expires; application-policy revocation after GraphQL restart is a separate verified mechanism.
3. **Real MCP client acceptance remains distinct.** Automated HTTP permission checks do not prove a Copilot/VS Code user-level configuration. The existing guide explicitly leaves that verification open; password-prompt support is unverified, not promised. Do not silently waive this criterion because the implementation issue is closed.
4. **UX limitations are recorded, not hidden.** Expired-session first-load header fallback can be blank. An unapproved Google identity can still see the login button. Neither grants write permission. Browser recipe deletion is intentionally absent and is not an acceptance requirement.
5. **Final acceptance is manual.** Incorporate completed provider evidence, resolve any remaining evidence gaps and obtain operator approval before closing the access-model issue. The separate public-launch task remains gated; this document neither enables exposure nor approves go-live.

## Operating and recovery instructions

Use the existing [browser authentication guide](browser-authentication.md) for policy format, local fixtures, portable MCP environment-variable setup, strict client configuration formats, origin protection and cookie/session behavior. Use [production Kubernetes operations](production-kubernetes.md) for private secret delivery, guarded deployment, configuration-triggered rollouts and private route boundaries. No new README setup path or alternate policy source is introduced.

- Role changes, token removal and rotation require GraphQL restart/replica rollout; editing the policy file alone is insufficient. Preserve token IDs when rotating secrets to preserve votes. Empty token/Google maps are valid.
- Keep secrets in private files/client process environments as documented, never in issue evidence, committed configuration or tool arguments. Browser Google identity is not an MCP credential; omit Authorization entirely for public MCP reads rather than send an empty token.
- Redis loss or cookie-key rotation requires browser login again. Provider client-secret changes require proxy restart. Template-only provider changes now trigger workload replacement via the rendered-manifest checksum.
- On denied or expired operations, return to public browsing or explicitly sign in; never replay a mutation automatically. Check outcome before retrying an interrupted write.
- Do not run destructive integration/E2E suites, regenerate Compose without its active Google inputs, restart authentication or sign in again during the ongoing revocation observation. Existing test commands in the guide are for an isolated testing stack, through the specified devcontainer runners.
