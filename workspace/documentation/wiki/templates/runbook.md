---
title: Runbook Template
parent: 4125949974
confluence-id:
---

<!-- TEMPLATE: runbook.
     1. Copy this file into NPG/<area>/ with a kebab-case filename.
     2. Set the title in Title Case (no dates) and the parent to a folder id from './publish.sh init'.
     3. Runbooks must end with a Rollback section: what to undo, in what order.
     4. Delete these HTML comments before publishing (the converter strips them).
     5. Labels to apply in Confluence after publish: npg-runbook -->

Replace with a summary of at most 3 sentences: what this runbook covers, when to run it, and the risk class of the procedure.

## Preconditions

<!-- State to check before running: alerts firing, access needed, maintenance window. -->

- Trigger condition: ...
- Access required: ...

## Procedure

<!-- Numbered, imperative, one action per step. Include the exact commands and expected output. -->

1. Check the current state:

```bash
command --status
```

2. Apply the change.
3. Confirm the change took effect.

## Verification

<!-- Post-procedure checks proving success. -->

- `command` prints the expected output.

## Rollback

<!-- Required for runbooks. What to undo, in reverse order, and how to confirm rollback worked. -->

1. Revert the change from step 2:

```bash
command --revert
```

2. Confirm the system returned to the pre-change state.

## Ownership

Owned by TEAM-NAME.
