# Deployment configuration inventory worksheet

This worksheet prepares the operator-led inventory for [#158](https://github.com/dhhyi/recipe-db/issues/158). It contains no deployment values and must stay a template in the repository. Complete a private copy outside every checkout; never add real secret values, tokens, private keys, kubeconfigs, account identifiers or sensitive paths here.

The intended default home for authoritative deployment configuration is `~/.config/recipe-db/`. This worksheet does not configure that directory, migrate existing inputs, or change any command. Do not copy, move, replace or delete existing files until the operator has reviewed the inventory, approved the layout and the repository workflow supports it.

## Inventory

Add a separate row for each actual input or setting. The examples identify areas to check, not an assertion that every item exists or should be copied.

| Item / purpose | Class: operator input, external setting or service-managed state | Authoritative source (record privately) | Consumer and deployed destination | Sensitivity and access | Preserve, regenerate, rotate or reconcile | Validation / recovery evidence | Operator review |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Deployment values, explicit target/context, storage identity and immutable release |  |  |  |  |  |  |  |
| Ansible inventory, SSH/bootstrap prerequisites, private kubeconfig and API tunnel access |  |  |  |  |  |  |  |
| Account policy, Google-account mappings and stable principal IDs |  |  |  |  |  |  |  |
| Google sign-in client configuration and secret, cookie/session keys and ingress secret |  |  |  |  |  |  |  |
| Typesense API key and operational/test bearer credentials |  |  |  |  |  |  |  |
| Google Drive Desktop OAuth client configuration and authorized `rclone` configuration |  |  |  |  |  |  |  |
| Backup configuration, private capture inputs, release coordination and scheduling |  |  |  |  |  |  |  |
| Domain, DNS, router/firewall, Google Console and HTTPS/ACME settings |  |  |  |  |  |  |  |
| Other discovered deployment-specific input, external setting or runtime state |  |  |  |  |  |  |  |

For each row, record what actually exists and its recovery treatment. Mark absent or inapplicable items explicitly. Keep secret contents out of the worksheet; record only a private reference when needed. Do not treat an authorized Drive refresh token as recoverable from the OAuth client JSON alone.

Classify each item carefully:

- **Operator input:** an approved desired value or secret with a known local source and deployment destination.
- **External setting:** state managed outside this repository, such as DNS, router policy or a Google Console setting; record the human action needed to recreate or verify it.
- **Service-managed state:** state created or refreshed by a running service. Define a reviewed reconciliation procedure; do not blindly replace newer state with an older workstation copy.

## Reconciliation checks

- Confirm target, cluster/context, storage identity, account behavior, stable identities and deployed release against operator-approved evidence.
- Distinguish inputs to preserve from settings that can be recreated, credentials that must be rotated, and runtime state that must be reconciled.
- Identify stale or conflicting copies without overwriting them. Record the resolution and its operator approval.
- Verify private ownership and permissions, references and path resolution without printing or publishing values.
- Record how a missing or invalid input, inaccessible target, failed partial synchronization and recovery from an empty workstation will be detected and reported.
- Track encrypted off-device storage and recovery separately. A local copy, client JSON, or configuration on a surviving device is not proof of independent recovery.

## Operator decisions still required

- Approve the completed inventory, final private directory layout and per-item preservation/regeneration treatment.
- Confirm the existing chezmoi encryption backend, encrypted Git destination, retrieval prerequisites and update procedure.
- Review the synchronization commands, exact target, credential-refresh handling and safe acceptance operation before any live change.
- Establish an independent Google-account access/recovery method and perform the encrypted recovery rehearsal.

Do not mark this issue complete based on this template or documentation alone. Keep the issue open until the human actions and acceptance evidence in [#158](https://github.com/dhhyi/recipe-db/issues/158) are verified.
