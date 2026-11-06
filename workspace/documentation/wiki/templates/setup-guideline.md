---
title: Setup Guideline Template
parent: 4125949974
confluence-id:
---

<!-- TEMPLATE: setup guideline.
     1. Copy this file into NPG/<area>/ with a kebab-case filename.
     2. Set the title in Title Case (no dates) and the parent to a folder id from './publish.sh init'.
     3. Replace every placeholder; delete these HTML comments before publishing (the converter strips them).
     4. Setup pages must end with a Verification section.
     5. Labels to apply in Confluence after publish: npg-setup -->

Replace with a summary of at most 3 sentences: what this setup produces, who needs it, and the expected end state.

## Prerequisites

<!-- List tools, access, and versions the reader needs before starting. -->

- Access to ...
- Tool X version Y or later

## Steps

<!-- Numbered steps, imperative voice, one action per step. Show exact commands in fenced blocks with a language tag. -->

1. Do the first action:

```bash
command --flag value
```

2. Do the second action.

## Verification

<!-- Required for setup pages. Show how to prove the setup works. -->

- `command` prints the expected output without errors.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| ... | ... | ... |

## Ownership

<!-- Team or person responsible for keeping this page current. -->

Owned by TEAM-NAME.
