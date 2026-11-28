---
name: implement-issue
description: Implement a GitHub issue or story, validate it, and obtain independent reviews. Use for requests such as "implement this issue", "fix issue 123", or "work on this story" when implementation is intended. Not for investigation or refinement alone.
---

# Implement an issue

- Follow [repository instructions](../../../AGENTS.md) and [issue completion rules](../../../CONTRIBUTING.md#hierarchy-dependencies-and-completion).
- Read the issue, discussion, applicable decisions, parent contract, and blockers. Implement only an authorized, settled `spec` with resolved blockers.
- Track every requirement and acceptance criterion; inspect relevant code and preserve unrelated changes. Ask the user about serious conflicts, unresolved decisions, or blockers.
- Implement the agreed scope and run targeted checks using repository/project instructions. Delegate other work when useful. Update documentation only as needed and follow the [documentation guidelines](../../../CONTRIBUTING.md#documentation).
- When backend behavior changes, check and update affected mocks using the [mock guidance](../../../docs/testing.md#checking-and-updating-mocks). Supply reviewers with the updates or explain why existing fixtures remain valid.
- Follow the repository's checkpoint policy and the user's branch, commit, and publication constraints.

## Independent reviews

- After implementation and validation, invoke both named custom agents as separate subagents, not generic substitutes:
  - [implementation-reviewer](../../agents/implementation-reviewer.agent.md): correctness, regressions, validation, and documentation.
  - [implementation-completeness](../../agents/implementation-completeness.agent.md): coverage of every requirement and acceptance criterion.
- When adding, modifying, or relocating tests, also invoke [test-placement-reviewer](../../agents/test-placement-reviewer.agent.md) as a separate subagent to recommend appropriate placement and identify duplicated behavioral coverage. For Bats tests, provide the suite-level validation evidence required by the [script testing guidance](../../../docs/testing.md#script-testing). Evaluate its recommendations: adopt useful changes or explain why the current placement is preferable. Recommendations do not mandate migrations or mock-heavy unit tests; report unmet or unverified script-test requirements as unresolved.
- Supply each reviewer the issue URL, decisions, baseline, complete in-scope diff (including committed, staged, unstaged, and untracked changes), changed paths, and validation results. Identify unrelated changes. Supply other inaccessible evidence as source text or a session artifact.
- Let reviewers inspect the actual files and derive their own findings. They may review in parallel; keep the snapshot stable. If any required review is unavailable or blocked, report the incomplete review rather than substituting self-review.
- Address valid findings, rerun affected checks, and request follow-up from affected reviewers. Explain rejected findings and report any unresolved or unverified work.
- Report the linked issue with its title, changes, validation, review outcomes, and blockers. Keep PR-backed issues open until merge; do not change issue metadata or create follow-up issues without authorization.
