# Bazel quality checks

Run the supported quality workflow from the repository root:

```sh
mise run --raw bazel-quality
```

After setting up a checkout, synchronize its generated configuration first with `mise run sync`. The quality task runs project generation and formatting in each project's devcontainer, records the selected host-tool and container identities, regenerates `BUILD.bazel`, and then builds `//:quality`. Preparation happens before Bazel checks so cacheable check actions never extract source archives or format their inputs. Formatting changes remain in the checkout for the Git hook or CI to review.

`//:quality` contains one check action per project, ShellCheck, and all script-test groups. The legacy `//:<project>_precommit` targets are aliases to the corresponding `//:<project>_check`; they do not schedule a second check.

The canonical `mise run --raw bazel` launcher supplies the stable PATH used by direct builds, hooks, and CI. The quality task also centralizes its action environment. CI intentionally adds `CI`, `GITHUB_ACTIONS`, Compose progress/concurrency settings, and `DEVCONTAINER_KEEP_RUNNING`; these meaningful differences may invalidate actions. Host identity records active Mise tool versions and platform without recording installation paths or arbitrary environment values. Project identity records the selected container image ID/platform and non-secret image/build/feature configuration. Container startup is reconciled before identities are written, and unresolved identities fail rather than falling back to an old success.

Checks use the checkout through devcontainers and are local-only Bazel actions (`no-sandbox`, `no-remote`). The identities help local and CI disk caches distinguish selected runtimes; they do not promise cache sharing across incompatible operating systems or architectures. Bazel PATH remains an explicit action input, so unrelated caller PATH entries do not change the check key.
