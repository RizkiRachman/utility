# NPG Wiki Style Guide

Rules for every page published from this repository. The publish gates enforce
the hard items; reviewers check the rest.

## Voice and tense

- Active voice, second person for instructions ("Run the container", not "The container should be run").
- Present tense for instructions and descriptions.
- Short sentences. One action per step.

## Naming

- Filenames: kebab-case (`rancher-desktop-setup.md`), no dates.
- Page titles: Title Case, no dates, no version numbers in the title.
- Keep headings short; use ATX style (`##`) only.

## Structure

- Every page opens with a summary of at most 3 sentences.
- Setup pages end with a `Verification` section.
- Runbooks end with a `Rollback` section.
- How-tos stay within 7 steps; split larger procedures into linked pages.
- Ownership goes at the bottom under an `Ownership` heading.

## Labels

- Lowercase, space-prefixed: `npg-setup`, `npg-runbook`, `npg-adr`, `npg-how-to`.
- Labels are applied in Confluence after the first publish (labels and attachments are out of scope for the publisher).

## Language hygiene (enforced by the humanizer gate)

- Hard blocks: em dashes beyond 2 per 100 words; "not just X but Y"; promotional wording ("seamless", "robust", "cutting-edge", "leverage" as a verb).
- Soft warnings: more than 3 "X, Y and Z" triples per page; more than 5 passive-voice candidates per page.
- Prefer commas, colons, and parentheses over dashes.

## Frontmatter

- Every page starts with `title`, `parent`, and an optional `confluence-id`.
- Absent or empty `confluence-id` means CREATE; a set id means UPDATE.
- Discover valid parent ids with `./publish.sh init`.

## Code and tables

- Fence code blocks with a language tag; the converter maps common aliases (sh → bash, yml → yaml, py → python).
- Keep tables narrow (5 columns or fewer); Confluence renders wide tables poorly.
- Put authoring notes in HTML comments; the converter strips them before publishing.
