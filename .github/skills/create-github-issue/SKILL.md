---
name: create-github-issue
description: Draft or create a GitHub issue in this repository. Use whenever the user asks to add, file, draft, or propose an issue.
---

# Create a GitHub issue

This skill covers new issues; to revise or refine an existing issue, use the `refine-issue` skill.

## Draft

Before drafting:

1. Read and follow the repository's [issue planning and refinement process](../../../CONTRIBUTING.md#issue-planning-and-refinement).
2. Use repository context and the user's description to write a clear, scoped issue. Do not invent reproduction details or settled requirements.

## Confirm before filing

Present the proposed title, complete body, and applicable metadata in chat. Then use the `ask_user` tool to ask whether the user approves creating the issue with that proposal. Use a yes/no question. Do not create the issue unless the user answers yes. A request to draft an issue is never authorization to file it.

## Create and verify

After the user confirms the proposal:

1. Create the issue in the intended repository using the approved proposal. Prefer the session's issue-creation tool for this repository unless the user explicitly requests another method.
2. Verify the creation result and report the issue link. If creation fails or any approved metadata could not be applied, say so plainly; do not claim success.

Creating an issue does not authorize implementation. Follow the repository's separate implementation-authorization rules.
