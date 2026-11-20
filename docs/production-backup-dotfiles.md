# Sync production backup inputs to dotfiles

Use this cookbook after preparing the operator-managed backup inputs for a release or restore. It saves the selected files in the private chezmoi repository; it does not install them on the Pi. See the [production configuration guide](production-configuration.md#private-workstation-directory) for file ownership and locations.

## 1. Stage and review the inputs

In the workstation fish shell where the calling procedure set `BACKUP_CONFIG_FILES` and `BACKUP_CONFIG_MESSAGE`, re-add only those managed files. Resolve their actual chezmoi source paths, including any private or encrypted filename attributes, before staging.

```fish
set -q BACKUP_CONFIG_FILES[1] BACKUP_CONFIG_MESSAGE[1]
and chezmoi git -- --no-pager diff --cached --exit-code --stat
and chezmoi re-add -- $BACKUP_CONFIG_FILES
and set -g BACKUP_CONFIG_SOURCES (chezmoi source-path -- $BACKUP_CONFIG_FILES)
and test (count $BACKUP_CONFIG_SOURCES) -eq (count $BACKUP_CONFIG_FILES)
and chezmoi git -- add -- $BACKUP_CONFIG_SOURCES
and chezmoi git -- --no-pager diff --cached -- $BACKUP_CONFIG_SOURCES
```

Stop if any command fails. If the private repository already has staged changes, handle them separately without automatically unstaging or committing them. Review the diff privately and continue only if it contains the intended changes. Do not copy private configuration diffs into chat.

## 2. Commit and push to the private repository

Review all unpushed commits on the current private branch before proceeding: the push publishes earlier unpushed commits too. In the same workstation fish shell:

```fish
chezmoi git -- commit --only -m "$BACKUP_CONFIG_MESSAGE" -- $BACKUP_CONFIG_SOURCES
and chezmoi git -- push
```

`--only` limits the commit to the selected source files. Return to the calling procedure only after both commands succeed.
