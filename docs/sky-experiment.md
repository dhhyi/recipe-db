# Sky experiment: shared styling

This guide evaluates Sky 0.29.12 for RecipeDB frontend work using the [counter experiment](../sky-experiment/src/Main.sky). It is for contributors deciding whether Sky fits the existing shared design, not a production adoption recommendation. See also the [design project](../design/.project.yaml) and [development configuration](../sky-experiment/.project.yaml).

## Contents

- [Trying the app](#trying-the-app)
- [What integrates cleanly](#what-integrates-cleanly)
- [The CSS reset limitation](#the-css-reset-limitation)
- [Assessment](#assessment)
- [Upstream issue draft](#upstream-issue-draft)

## Trying the app

On the workstation, from the repository root:

```fish
mise install
mise run dev-up
```

Open <http://localhost:8080/sky-experiment/>. The shared header and footer, headings, paragraphs and three counter buttons should appear. Decrement can go below zero; reset returns to zero. Counter state is in a per-browser Sky.Live session in memory, not application storage. Restarting the service loses it.

For development, open the generated Sky experiment devcontainer and run its **Run Sky watch server** task. Stop the Compose `sky-experiment` service first so ingress does not discover two services with the same route.

## What integrates cleanly

The `version = "0.1.0"` in [sky.toml](../sky-experiment/sky.toml) versions this experiment, not the Sky compiler. Both the [devcontainer configuration](../sky-experiment/.project.yaml) and [production Dockerfile](../sky-experiment/Dockerfile) pin the compiler to `0.29.12`. Check the installed compiler with `mise run --raw in-devcontainer sky-experiment sky --version`, not the application manifest.

- `Std.App.web` accepts a typed `Std.Html` view directly. HTML tags, attributes and click handlers are ordinary Sky functions; no raw HTML strings or custom counter JavaScript are necessary.
- The page loads `/design/styles.css`, `/design/components.js` and shared htmx. It uses the real `header-component`, `/identity` response and `footer-component`; it does not recreate them. Sky handles only counter state and rendering.
- Existing project metadata adds the app to Compose, devcontainer generation, builds and Tailwind source discovery. There is no separate CSS build.
- Sky.Live supports the `/sky-experiment` mount through `SKY_LIVE_BASE_PATH` and the usual ingress prefix stripping. Its events and scripts stay under that prefix.
- The production Dockerfile builds a native executable, not a browser Wasm bundle. The compiler download is version-pinned and checksum-verified for AMD64 and ARM64.

This is the supported web-only HTML API, **not** `Std.Ui.html` wrapped around every element. It does mean choosing an HTML view rather than Sky's portable, typed layout DSL. The [upstream app API](https://github.com/anzellai/sky/blob/v0.29.12/sky-stdlib/Std/App.sky) distinguishes `App.web` from `App.app`.

## The CSS reset limitation

**Importing our stylesheet is not sufficient, even with `App.web`.** [Sky.Live's page wrapper](https://github.com/anzellai/sky/blob/v0.29.12/runtime-go/rt/live.go) unconditionally injects [`liveBaseCSS`](https://github.com/anzellai/sky/blob/v0.29.12/runtime-go/rt/live_core.go). It resets heading and paragraph typography, margins, button padding and other properties. It also supplies page-root layout rules.

The shared design uses named CSS cascade layers. Sky's reset is unlayered, so its normal declarations outrank normal declarations inside those layers, regardless of stylesheet loading order. Moving our stylesheet after the reset does not solve this. It also affects the shared header's light-DOM contents.

The isolated [compatibility bridge](../sky-experiment/public/design-compat.js) wraps that runtime style block in `@layer sky-runtime`. The page declares this layer before the shared design's layers. Thus shared rules win without copying them, patching the compiler, or accumulating per-element overrides. The bridge also restores `body` font inheritance: otherwise Sky's body font and line-height still mask typography inherited from the design's `html` rules, even in a lower layer.

**This is an unsupported workaround, not a Sky extension API.** It depends on the pinned runtime's inline reset signature and page structure, and throws an explicit error if that signature is absent or ambiguous. A runtime change that preserves the signature can still require review. The bridge requires JavaScript and runs after document parsing; a flash of reset styling is possible, and with JavaScript disabled the reset remains uncorrected. It is not a robust production styling contract.

The bridge also sets the document language, which Sky's generated wrapper does not obtain from this HTML view. A configurable document shell would avoid that adjustment.

## Assessment

**The concern is substantially reinforced, but the obstacle is narrower than "Sky cannot reuse CSS."** Typed HTML rendering and custom-element reuse are straightforward. The main integration debt in this POC is the mandatory global reset, not the counter or the shared components.

For an HTML-first Sky.Live app, ongoing view work resembles Elm's `Html` API: write semantic elements, reuse existing class names, and use Sky messages for interactions. No design-system rewrite is needed. The compatibility bridge is small, but its unsupported dependency makes upgrades riskier than its size suggests.

`Std.Ui` is a different tradeoff: it emits inline layout styles and introduces its own page layout. CSS classes exist, but importing our design does not make the DSL's defaults disappear. Reproducing our existing layout with that DSL would need deliberate mapping and integration testing. This POC does **not** establish that arbitrary `Std.Ui` components or Sky.Spa can adopt our CSS unchanged.

Sky.Live also moves clicks over HTTP and keeps server-side sessions. That is extra latency and operational state compared with client-side Elm interactions; it is separate from CSS compatibility. There are no backend data operations in this experiment.

Recommendation: keep this as an experiment; do not adopt Sky for this frontend until reset control is supported upstream. A documented opt-out or low-priority reset layer would remove the principal styling workaround. Browser tests should still compare shared controls with plain HTML when upgrading. Sky manifests, embedded compiler dependencies and generated Go dependencies are not covered by the repository's Dependabot configuration.

## Upstream issue draft

Suggested title: **Allow disabling or layering the global CSS reset in HTML apps**

Not filed upstream.

**Version:** Sky 0.29.12, `Std.App.web` / Sky.Live.

**Reproduction:** render a heading, paragraph and button with `Std.Html`; load an external design stylesheet containing layered rules:

```css
@layer design {
  h2 {
    font-size: 1.5rem;
    margin-bottom: 1rem;
  }
  button {
    padding: 0.75rem 1rem;
  }
}
```

**Actual:** the unconditional, unlayered `liveBaseCSS` overrides those rules, even though the app does not use `Std.Ui`. External light-DOM web components are affected too. Changing stylesheet order does not fix cascade-layer precedence.

**Expected:** a supported app configuration to disable the reset while retaining the runtime mount's necessary layout, or place the reset in a documented low-priority cascade layer. Preserve existing defaults for current apps.

**Current workaround:** after parsing, locate the generated reset style and wrap it in an earlier named layer. This depends on generated markup and needs JavaScript, so it is unsuitable as a durable integration contract.

**Requested coverage:** plain HTML with layered external CSS; `Std.Ui` default layout unchanged; both Sky.Live and Sky.Spa if they share the reset; documented behavior without JavaScript and under a strict Content Security Policy.
