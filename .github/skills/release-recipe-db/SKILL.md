---
name: release-recipe-db
description: Guide an operator through a fresh Recipe DB production release using calm, direct and simple language, one small command batch at a time, and the authoritative release cookbook and configuration guide.
---

# Guide a Recipe DB release

The [release cookbook](../../../docs/production-release-cookbook.md) is the source of truth for release steps. The [production configuration guide](../../../docs/production-configuration.md) is the source of truth for configuration values, their authoritative sources, ownership and workstation-to-Pi mappings. Read both without waiting for the operator to point them out. Follow [repository instructions](../../../AGENTS.md).

This skill defines communication and pacing, not a second release procedure. Do not duplicate the cookbook's steps, commands or configuration inventories here. Derive each instruction batch from the current authoritative documents.

## Contents

- [Agree who runs commands](#agree-who-runs-commands)
- [Establish the starting point](#establish-the-starting-point)
- [Guide one batch at a time](#guide-one-batch-at-a-time)
- [Handle failures and aborts](#handle-failures-and-aborts)

## Agree who runs commands

- Before operational checks, ask whether the operator wants to run all commands or delegate specified read-only checks to the agent. Agree on the scope, such as local Git/GitHub inspection or selected read-only cluster checks. Until agreed, leave command execution with the operator; do not assume delegation from skill invocation or lack of password prompts.
- Before each delegated batch, tell the operator which commands will run, where, and why. Report the results and any failures before advancing; do not silently run checks in the background. Pause for decisions rather than treating delegation as approval of the next step.
- If an agreed check requires interactive authentication the agent cannot complete, hand it to the operator. Never request secrets in chat or bypass authentication.
- Read-only delegation does not authorize Git fetches, tagging, pushes, tool installation, backups, rehearsals or other state-changing operations. These remain operator-guided; agent execution needs separate explicit authorization. An isolated rehearsal is not a read-only check.
- For example, when candidate inspection is delegated, inspect the published run, checkout and local/remote tags, then propose the verified SHA, artifact digest and next candidate tag with supporting results. Wait for approval before providing the modifying commands. Set needed variables in the operator's terminal; do not rely on variables in the agent's shell.
- Keep this responsibility agreement in the skill, not the cookbook. The cookbook must remain a complete procedure an operator can follow without an AI.

## Establish the starting point

- Each session starts a fresh release attempt. Complete it in that session or abort it; do not offer cross-session resumption. An earlier aborted attempt may leave state requiring documented recovery, not permission to restart commands blindly.
- Inspect the starting state read-only using the cookbook's checks. Do not reuse versions, release identities or configuration values from an earlier conversation without verification.
- Use the configuration guide to locate the actual operator-held inputs yourself. Respect its distinction between authoritative configuration, generated credentials and live Pi state. Verify relevant deployed identities read-only; if private inputs and the Pi disagree, stop and explain the mismatch rather than assuming either is current.
- Open with a short overview derived from the cookbook, explaining the purpose of the upcoming work without reproducing the entire procedure.
- Present only the first actionable batch, then pause. Invoking this skill does not authorize operational changes.

## Guide one batch at a time

Use calm, direct and simple language: short sentences, ordinary words, and brief explanations of necessary technical terms. Be encouraging without promising success or a completion time. Avoid alarmist wording, excessive reassurance and streams of progress narration.

Keep each instruction page to roughly one screen:

1. **Where we are:** cookbook step and the immediate goal.
2. **Why:** one or two sentences explaining this batch.
3. **Where to run it and impact:** workstation, provisioning devcontainer or Pi; read-only, isolated local work or production mutation. Mention downtime or data deletion before commands.
4. **Commands:** one coherent, copy-pasteable batch using verified values.
5. **Expected result and stop condition:** what proves success, when to stop, and the minimal non-sensitive result needed next.

- For operator-run batches, wait for the operator's result before advancing. Acknowledge it briefly and validate the relevant evidence; do not automatically chain through subsequent steps.
- Follow the agreed command responsibilities. Do not silently execute an upgrade, rehearsal, deployment, migration, access change, cleanup or publication.
- Assume the operator can use workstation fish, a Pi SSH session as `piadmin` with POSIX-compatible commands, and the provisioning container's SSH-agent Bash shell. Ask the operator to open a missing shell or Kubernetes tunnel. Do not attempt protected SSH or sudo yourself when their key-passphrase/password prompts cannot be answered.
- Give each command in its actual shell. Do not wrap Pi commands in workstation `ssh host 'command'` one-liners. Plain SSH connection/tunnel setup and operator-authenticated internal file transport by the release controller are distinct from those one-liners.
- Keep normal release orchestration on the workstation. The existing privileged backup service still captures and uploads on the Pi, including the post-release check after guarded candidate alignment. Other normal Pi operations are narrow host/file requests; no root developer setup or long-running privileged release controller. Explicitly approved failure recovery may use the managed Pi toolchain with elevated privileges; this never authorizes root development setup or automatic recovery/reopening.
- Use fish-compatible workstation commands. Commands inside another shell must be clearly labelled. Split preparation from long-running execution when combining them would overwhelm the page.
- Before presenting every script or command batch, double-check that all placeholders are filled with relevant, verified values from the sources identified by the configuration guide and cookbook. Check that referenced files exist, shell variables are set in the terminal where they will be used, and values identify the intended release and target. Do not print secret values.
- Never present executable instructions containing unresolved placeholders or "insert the path yourself." Resolve discoverable values yourself; if a required value cannot be verified, stop and ask before providing the executable batch. Do not guess among multiple files or targets.
- Make batch failures stop dependent actions. Never allow a failed copy, parse or validation to fall through into a migration or deployment.
- Explain expected prompts, silent commands and terminals that must stay open. Preserve interactive authentication; never request passwords, tokens, private keys or backup contents in chat.
- Keep verbose diagnostics in private logs as appropriate. Do not ask the operator to paste whole production logs or backups; inspect local files yourself when available.
- Do not wait indefinitely for unrelated work. If a gate is pending, report what is pending and whether any safe preparation can proceed; do not poll silently for long periods or relax the gate.

For example, after a download succeeds, locate and verify its exact output paths before preparing the next batch. Do not ask the operator to replace example paths or make them repeat information already available locally.

## Handle failures and aborts

- Stop the release sequence on failure. Say which phase failed, what actually ran, whether production was touched and what remains uncertain. Do not infer safety from a generic error message.
- Inspect retained diagnostics read-only before proposing a retry within the session. Follow the cookbook's recovery and cleanup rules rather than inventing shortcuts.
- Distinguish what has actually been verified from what is still pending. Do not present a passing component check as proof that the full release is safe.
- Explain the next bounded diagnostic or repair action and its impact before execution. Do not turn release guidance into unannounced code changes or infrastructure upgrades.
- If a fix requires a PR, stop the release attempt, follow the operator's requested PR workflow, and identify what must be revalidated after merge. Do not quietly continue using unmerged fixes or an older artifact.
- If the operator aborts, stop advancing the release. Report the observed production and maintenance state, retained evidence and any recovery still required. Aborting does not authorize automatic cleanup, rollback, reopening access or a later resumed release attempt.
- Respect a change of scope immediately, including "no more releases this session" or "leave this draft uncommitted."

Reusable starting prompt:

> Use the release-recipe-db skill for a fresh production release. Read the current release cookbook and production configuration guide as the sources of truth. First agree with me which read-only checks, if any, you may run; announce those checks before execution and report their results. Use calm, direct and simple language. Give me a short overview, then one small command batch at a time: why, where, impact and expected result. Find configuration values and exact paths, double-check that no placeholders remain, use fish-compatible workstation commands, and wait for my result on operator-run batches before continuing. Do not make production changes without my explicit confirmation. We finish this attempt in this session or abort it.
