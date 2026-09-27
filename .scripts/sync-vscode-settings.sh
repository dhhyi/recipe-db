#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"

set --
for project_file in */.project.yaml; do
  set -- "$@" "${project_file%/.project.yaml}"
done

echo "Writing .vscode/settings.json ..."
mkdir -p .vscode
# ${workspaceFolder} is a VS Code placeholder and must stay unexpanded
# shellcheck disable=SC2016
mise exec -- jq -n --args '
  {
    "extensions.ignoreRecommendations": true,
    "task.autoDetect": "off",
    "runOnSave.commands": [
      {
        match: "(^|/)\\.gitignore$",
        command: "cd ${workspaceFolder} && mise run sync-ignore-files",
        runningStatusMessage: "synchronizing...",
        finishStatusMessage: "synchronizing ✔"
      },
      {
        match: "^\\.scripts/(check|sync)-[^/]*\\.sh$",
        command: "cd ${workspaceFolder} && mise run sync-files",
        runningStatusMessage: "synchronizing...",
        finishStatusMessage: "synchronizing ✔"
      }
    ] + ($ARGS.positional | map({
      match: "/\(.)/\\.project\\.yaml$",
      command: "cd ${workspaceFolder} && mise run sync-files && sh \(.)/.update_devcontainer.sh",
      runningStatusMessage: "\(.) devcontainer...",
      finishStatusMessage: "\(.) devcontainer ✔"
    }))
  }
' "$@" > .vscode/settings.json
