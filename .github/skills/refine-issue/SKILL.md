---
name: refine-issue
description: Refine a GitHub idea issue into an agent-ready spec, an umbrella, or an umbrella-scoped decision. Use when asked to refine an issue or settle its requirements.
---

# Refine an issue

Follow [CONTRIBUTING.md](../../../CONTRIBUTING.md) and [AGENTS.md](../../../AGENTS.md). Refine future work; do not implement it during this workflow.

## Gather context

1. Require an issue number or GitHub URL. Ask with `ask_user` if missing.
2. Read the issue, discussion, labels, native parent/sub-issues, and blocked-by relationships. Read its umbrella's base contract and relevant repository context.
3. Require `idea` as its sole workflow label among `idea`, `umbrella`, `spec`, and `decision`. Otherwise stop and explain the mismatch; do not silently relabel it.
4. Summarize the problem, known requirements, relevant decisions, dependencies, and open questions before asking questions.

## Refine with the user

Use `ask_user` to resolve material requirements and agree on the outcome. Do not invent decisions or require every minor implementation detail to be settled.

- **`spec`:** Define scope, expected behavior, constraints, dependencies, and verifiable acceptance criteria sufficient for autonomous implementation. Respect the umbrella's base contract; leave minor implementation choices to the agent and review.
- **`umbrella`:** Define the overall outcome, scope, completion criteria, and proposed native sub-issues, initially labeled `idea`. Capture each child's problem or wish without prematurely specifying it. Identify ordering, dependencies, and any existing base-contract decisions.
- **`decision`:** Allowed only when the idea already belongs to an umbrella. Record context, chosen approach, alternatives, and consequences. The umbrella must reference it as part of its base contract. For material contract changes, explicitly supersede the prior decision and identify affected specs for review.

Standalone ideas may become only specs or umbrellas. Keep unresolved research, exploration, or requirements as `idea`; record settled findings and remaining questions without implying implementation readiness.

## Persist and verify

1. Present the proposed issue content and related changes for user confirmation before applying them.
2. Update the existing issue's description, preserving its identity, discussion, and relevant context. Replace `idea` with exactly one agreed workflow label; preserve other metadata labels.
3. For an umbrella, create the agreed native sub-issues or attach existing ones without duplicating work. Only umbrellas may own sub-issues. If the refined issue becomes an umbrella, attach its children directly to it.
4. Model dependencies with native GitHub blocked-by relationships, including external dependencies. Do not substitute labels or diagram arrows for native relationships.
5. Update every affected umbrella's main description in the same task: base-contract links, progress, open questions, next steps, and a Mermaid `flowchart TD` of implementation order and dependencies among its direct sub-issues. Link every issue node to its GitHub URL using a `click` directive. Use prerequisite-to-dependent arrows matching native blockers; document external dependencies outside the diagram. Contract references are not automatically blockers.
6. Close accepted decisions, but leave newly refined specs and umbrellas open. Refinement is not implementation; blockers must be resolved before implementing a spec.
7. Re-read affected issues and verify descriptions, exclusive workflow labels, hierarchy, dependencies, decision links, and diagrams. Report issue links and any incomplete updates explicitly; do not claim success if persistence failed.
