---
name: create-pr
description: Create a pull request for the current session. Use when the user wants to open a PR with the session's changes.
---

# Create Pull Request

Use the GitHub MCP server to create a pull request if available, otherwise use `gh` CLI.

Do not run additional compile tasks; pre-commit hooks handle validation.

1. Check for uncommitted changes. If any exist, ask the user what to do and wait for their decision. Do not automatically invoke the `/commit` skill. Commit only with explicit user approval; if the user chooses to leave changes uncommitted, exclude them from the PR's claimed changes.
2. Review all changes in the current session and identify which are included in the PR.
3. Write a concise PR title starting with a capital letter, without an area prefix. The PR metadata workflow adds linked issue numbers. If the user wants the PR to stay in draft, open it as a draft with `[WIP]` in the title.
4. Write a description covering what changed, why, and anything reviewers should know. Include `Closes #<number>` only for issues the PR fully resolves; leave them open until merge. Report implementation as awaiting review, not complete.
5. Create the pull request, passing `show_ui=false` so the PR is created without opening a confirmation UI.
