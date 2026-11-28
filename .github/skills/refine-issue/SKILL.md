---
name: refine-issue
description: Refine GitHub issues, classify manual tasks requiring human involvement, revise existing specs, split specs into umbrellas and child specs, restructure umbrellas, or record and revisit standalone or umbrella-scoped decisions. Use when asked to refine, split, or reorganize issues or settle their requirements.
---

# Refine an issue

Follow the canonical [issue process](../../../CONTRIBUTING.md#issue-planning-and-refinement). This workflow does not authorize implementation, including documentation edits. If the user mixes refinement and implementation without clear authorization, clarify the next action before proceeding.

During a refinement session, change only GitHub issue artifacts needed to record the agreed specification; do not modify repository files or create commits. Record requested code or documentation changes as implementation scope or acceptance criteria. Begin implementation only when the user explicitly requests it.

Never use the Ask User tool (`ask_user`) during a refinement session. Ask all questions and request all confirmations in chat, including missing issue details, design choices and approval to persist changes. End the turn and wait for the user's reply.

- [Gather context](#gather-context)
- [Refine with the user](#refine-with-the-user)
- [Persist and verify](#persist-and-verify)

## Gather context

1. Require an issue number or GitHub URL. If missing, ask for it.
2. Read the issue, discussion, labels, native parent/sub-issues, blocked-by and relates-to relationships. Read applicable decision contracts, its umbrella's base contract if present, and relevant repository context.
3. Accept `idea`, `spec`, `manual`, `umbrella`, or `decision` as the issue's sole workflow label. If the label is missing or multiple workflow labels are present, resolve the mismatch with the user rather than silently relabeling it. An existing spec, manual task, umbrella, or decision is not a reason to stop.
4. Explain the problem, known requirements, relevant decisions, dependencies, and open questions in chat. Distinguish existing agreements from suggestions and unresolved choices.

## Refine with the user

Treat the user as a technical design partner. Refinement is a conversation, not a race to produce a spec. Discuss one coherent topic at a time, incorporate the user's ideas, and iterate before moving on. Do not ask the user to choose a workflow label or approve a spec as a substitute for resolving its design.

- Explore the intended user or operator workflow, including important states, failure handling and consequences. Present relevant alternatives and tradeoffs without limiting the user to suggested choices.
- For UI work, develop and revise wireframes together before specifying the interface. Use lightweight text sketches or another suitable format, covering relevant viewport sizes and interaction states; a wireframe is a discussion aid, not an implemented design. Discuss navigation, controls and accessibility where applicable.
- Discuss relevant technologies, architecture and implementation approaches when they affect the outcome or the user wants a say. Explain constraints and tradeoffs, welcome alternatives, and record agreed decisions. Leave only genuinely minor choices that the user is happy to delegate to implementation.
- Separate agreed requirements from proposals and unresolved questions throughout. A user's interest in becoming a spec does not settle the design, search behavior, technology or other details implied by an agent's suggested option.
- Before drafting a spec, review the material open questions with the user and resolve them through discussion. If they remain open, keep the affected scope as an `idea` or capture it as an unresolved child where appropriate; do not fill gaps with assumptions.

- **Existing plans:** Revise specs and restructure umbrellas in place. Preserve settled requirements, acceptance criteria, implementation progress, and relevant discussion unless the user agrees to change them. Ask only about new or affected material questions, not requirements already settled.
- **Splitting a spec:** Convert the existing issue to an umbrella, preserving its identity and overall outcome. Propose child scopes and map every existing requirement and acceptance criterion to the children or umbrella-level completion criteria so nothing is lost. Children that preserve fully settled, implementation-ready scope may be created directly as `spec`; use `idea` only for scope needing further refinement. Reuse existing issues where appropriate and review incoming and outgoing dependencies against the split rather than blindly copying them.
- **`spec`:** Define scope, expected behavior, constraints, dependencies, and verifiable acceptance criteria sufficient for autonomous implementation. Respect applicable standalone decisions and the umbrella's base contract if present; leave implementation choices open only when the user agrees to delegate them.
- **`manual`:** Any idea, or an existing spec, may become manual when completion requires the operator's direct action or approval rather than autonomous execution. Record required human actions, prerequisites, completion evidence, safety boundaries, and unresolved requirements; preserve settled scope and acceptance criteria. Agents may refine, prepare checklists, and assist, but must not independently execute human-only steps or claim completion. The label does not imply readiness or waive blockers. Separate automatable specs from manual steps when practical, using an umbrella if a parent is needed.
- **`umbrella`:** Define or update the overall outcome, scope, completion criteria, and proposed native sub-issues. New, unresolved child scopes start as `idea`; preserve existing specs and use the splitting rules above for already-settled scope. Capture unresolved problems or wishes without prematurely specifying them. Identify ordering, dependencies, and any existing base-contract decisions.
- **`decision`:** May stand alone or belong to an umbrella. Record context, chosen approach, alternatives, and consequences. Relate standalone decisions to affected issues with native "Relates to" relationships and link the contract in their descriptions; do not create an umbrella solely to hold a decision. An owning umbrella must reference the decision as part of its base contract. When revisiting an accepted decision, preserve the historical agreement; propose a new, explicitly superseding decision for material contract changes and identify affected specs for review. Do not silently rewrite the accepted contract.

## Persist and verify

1. Present the proposed issue content and related changes, then end the turn and wait for confirmation. Announcing a plan is not confirmation; approval to persist refinement is not approval to implement.
2. Update the existing issue's description, preserving its identity, discussion, and relevant context. Retain its workflow label when the type is unchanged; otherwise replace it with exactly one agreed workflow label. Preserve other metadata labels. For material changes to an accepted contract, create a separate, explicitly superseding decision and link the old and new decisions.
3. For an umbrella, create the agreed native sub-issues or attach existing ones without duplicating work.
4. Update dependencies and decision relationships according to the [relationship rules](../../../CONTRIBUTING.md#hierarchy-dependencies-and-completion).
5. Update every affected umbrella's main description in the same task: base-contract links, progress, open questions, next steps, and its diagram following the [diagram rules](../../../CONTRIBUTING.md#hierarchy-dependencies-and-completion).
6. Preserve completion state unless an approved change requires otherwise. Follow the [completion rules](../../../CONTRIBUTING.md#hierarchy-dependencies-and-completion).
7. Re-read affected issues and verify descriptions, exclusive workflow labels, hierarchy, dependencies, native relates-to relationships, and decision links. Verify diagrams against the diagram rules. For splits, verify that every original requirement and acceptance criterion is still covered and progress is preserved. Report issue links and any incomplete updates explicitly; do not claim success if persistence failed.
