# Sky experiment: shared styling

This guide evaluates Sky 0.31.2 for RecipeDB frontend work using the [counter experiment](../sky-experiment/src/Main.sky). It is for contributors deciding whether Sky fits the existing shared design, not a production adoption recommendation. See also the [design project](../design/.project.yaml) and [development configuration](../sky-experiment/.project.yaml).

## Contents

- [Trying the app](#trying-the-app)
- [Shared design integration](#shared-design-integration)
- [Assessment](#assessment)

## Trying the app

On the workstation, from the repository root:

```fish
mise install
mise run dev-up
```

Open <http://localhost:8080/sky-experiment/>. The shared header and footer, headings, paragraphs and three counter buttons should appear. Decrement can go below zero; reset returns to zero. Counter state is in a per-browser Sky.Live session in memory, not application storage. Restarting the service loses it.

For development, open the generated Sky experiment devcontainer and run its **Run Sky watch server** task. Stop the Compose `sky-experiment` service first so ingress does not discover two services with the same route.

The `version = "0.1.0"` in [sky.toml](../sky-experiment/sky.toml) versions this experiment, not the Sky compiler. Both the [devcontainer configuration](../sky-experiment/.project.yaml) and [production Dockerfile](../sky-experiment/Dockerfile) pin the compiler to `0.31.2`. Check the installed compiler with `mise run --raw in-devcontainer sky-experiment sky --version`, not the application manifest.

## Shared design integration

`Std.App.web` accepts a typed `Std.Html` view directly. The page loads the shared stylesheet, header and footer components, and htmx without recreating them; Sky handles counter state and rendering. `App.withDocument` sets the document language on the initial response.

Sky 0.29.13 fixed the global reset conflict reported in [upstream issue #328](https://github.com/anzellai/sky/issues/328): the visual reset now uses an early `sky-reset` cascade layer, and default typography is set on `html` rather than `body`. The experiment needs no reset-rewriting JavaScript or custom layer order. Sky's runtime layout rules remain unlayered.

Project metadata adds the app to Compose and Tailwind source discovery. Sky.Live supports the `/sky-experiment` mount through `SKY_LIVE_BASE_PATH` and ingress prefix stripping. The production Dockerfile builds a native executable; compiler downloads are pinned and checksum-verified for AMD64 and ARM64.

## Assessment

Sky is no longer ruled out by the reset conflict for an HTML-first Sky.Live frontend using the shared design. Its typed HTML and event model work with the existing CSS and custom elements without an unsupported styling bridge. The experiment is not a production adoption recommendation.

`Std.Ui` is a different tradeoff: it emits inline layout styles and introduces its own page layout. This POC does **not** establish that arbitrary `Std.Ui` components or Sky.Spa can adopt our CSS unchanged.

Sky.Live sends interactions over HTTP and keeps server-side sessions. That adds latency and operational state compared with client-side Elm; the experiment does not exercise backend data operations. Sky manifests, embedded compiler dependencies and generated Go dependencies are not covered by the repository's Dependabot configuration.
