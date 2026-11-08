---
name: commit
description: Commit staged or unstaged changes. Use when asked to commit, save work, or check in code.
---

<!-- Customize this skill and select save to override its behavior. Delete that copy to restore the built-in behavior. -->

# Commit Changes

## Guidelines

- **Never amend existing commits** without asking.
- **Never force-push or push** without explicit user approval.
- **Never skip pre-commit hooks** (do not use `--no-verify`).
- **Never skip signing commits** (do not use `--no-gpg-sign`).
- **Never revert, reset, or discard user changes** unless the user explicitly asked for that.
- Check for obvious secrets or generated artifacts that should not be committed. If something looks risky - ask the user.
- When in doubt about staging or message content, ask the user.

## Workflow

### 1. Check repository status

```
git status --short
```

- If there are **no changes** (working tree clean, nothing staged), inform the user and stop.
- If there are **staged changes**, proceed with those and do not stage any unstaged changes.
- If there are **only unstaged changes**, stage everything (`git add -A`), and proceed with those.

### 2. Generate the commit message

Obtain the full diff of what will be committed:

```bash
git diff --cached --stat
git diff --cached
```

Draft the message from the diff:

- A concise title (≤ 72 characters) starting with a capital letter. No prefixes or emoji.
- A brief body with a few relevant details about the change and its intent.
- Include the required `Co-authored-by` trailer.

### 3. Commit

```
git commit -m "<subject>" -m "<body>"
```

### 4. Handle failures and confirm

- Check the commit output and exit status.
- If hooks aborted because formatters changed files, review those edits, stage only formatter changes belonging to the intended commit, and retry the commit without asking again. Preserve unrelated unstaged changes.
- For other failures, diagnose and address the reported error before retrying; do not treat them as formatting failures or bypass hooks.
- After success, run `git status --short` and `git log --oneline -1`; report the commit and any remaining changes.
