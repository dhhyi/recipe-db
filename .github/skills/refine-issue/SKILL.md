---
name: refine-issue
description: Refine GitHub issues, revise existing specs, split specs into umbrellas and child specs, restructure umbrellas, or revisit umbrella-scoped decisions. Use when asked to refine, split, or reorganize issues or settle their requirements.
---

# Refine an issue

Follow [CONTRIBUTING.md](../../../CONTRIBUTING.md) and [AGENTS.md](../../../AGENTS.md). Refine future work; do not implement it during this workflow.

## Gather context

1. Require an issue number or GitHub URL. Ask with `ask_user` if missing.
2. Read the issue, discussion, labels, native parent/sub-issues, and blocked-by relationships. Read its umbrella's base contract and relevant repository context.
3. Accept `idea`, `spec`, `umbrella`, or `decision` as the issue's sole workflow label. If the label is missing or multiple workflow labels are present, resolve the mismatch with the user rather than silently relabeling it. An existing spec, umbrella, or decision is not a reason to stop.
4. Summarize the problem, known requirements, relevant decisions, dependencies, and open questions before asking questions.

## Refine with the user

Use `ask_user` to resolve material requirements and agree on the outcome. Do not invent decisions or require every minor implementation detail to be settled.

- **Existing plans:** Revise specs and restructure umbrellas in place. Preserve settled requirements, acceptance criteria, implementation progress, and relevant discussion unless the user agrees to change them. Ask only about new or affected material questions, not requirements already settled.
- **Splitting a spec:** Convert the existing issue to an umbrella, preserving its identity and overall outcome. Propose child scopes and map every existing requirement and acceptance criterion to the children or umbrella-level completion criteria so nothing is lost. Children that preserve fully settled, implementation-ready scope may be created directly as `spec`; use `idea` only for scope needing further refinement. Reuse existing issues where appropriate and review incoming and outgoing dependencies against the split rather than blindly copying them.
- **`spec`:** Define scope, expected behavior, constraints, dependencies, and verifiable acceptance criteria sufficient for autonomous implementation. Respect the umbrella's base contract; leave minor implementation choices to the agent and review.
- **`umbrella`:** Define or update the overall outcome, scope, completion criteria, and proposed native sub-issues. New, unresolved child scopes start as `idea`; preserve existing specs and use the splitting rules above for already-settled scope. Capture unresolved problems or wishes without prematurely specifying them. Identify ordering, dependencies, and any existing base-contract decisions.
- **`decision`:** Allowed only under an umbrella. Record context, chosen approach, alternatives, and consequences. The umbrella must reference it as part of its base contract. When revisiting an accepted decision, preserve the historical agreement; propose a new, explicitly superseding decision for material contract changes and identify affected specs for review. Do not silently rewrite the accepted contract.

Standalone ideas may become only specs or umbrellas. Keep unresolved research, exploration, or requirements as `idea`; record settled findings and remaining questions without implying implementation readiness.

## Persist and verify

1. Present the proposed issue content and related changes for user confirmation before applying them.
2. Update the existing issue's description, preserving its identity, discussion, and relevant context. Retain its workflow label when the type is unchanged; otherwise replace it with exactly one agreed workflow label. Preserve other metadata labels. For material changes to an accepted contract, create a separate, explicitly superseding decision and link the old and new decisions.
3. For an umbrella, create the agreed native sub-issues or attach existing ones without duplicating work. Preserve settled child specs; create split-out, implementation-ready children as specs and unresolved children as ideas. Only umbrellas may own sub-issues. If the refined issue becomes an umbrella, attach its children directly to it.
4. Model dependencies with native GitHub blocked-by relationships, including external dependencies. Do not substitute labels or diagram arrows for native relationships.
5. Update every affected umbrella's main description in the same task: base-contract links, progress, open questions, next steps, and a Mermaid `flowchart TD` of implementation order and dependencies among its direct sub-issues. Each node label must contain only the issue number and current issue title, followed by ` (closed)` if the issue is closed (for example, `#123 Issue title (closed)`). Do not add other metadata to node labels or include PR references anywhere in the diagram. Link every issue node to its GitHub URL using a `click` directive. Use prerequisite-to-dependent arrows matching native blockers; document external dependencies outside the diagram. Contract references are not automatically blockers.
6. Close accepted decisions, but leave new specs and umbrellas open. Preserve existing completion state unless the agreed scope change requires reopening; never close specs or umbrellas merely because refinement is complete. Refinement is not implementation; blockers must be resolved before implementing a spec.
7. Re-read affected issues and verify descriptions, exclusive workflow labels, hierarchy, dependencies, decision links, and diagrams, including current issue numbers, titles, closed markers, and absence of PR references. For splits, verify that every original requirement and acceptance criterion is still covered and progress is preserved. Report issue links and any incomplete updates explicitly; do not claim success if persistence failed.
