# NPG Wiki Publisher

Markdown-first authoring for the NPG Confluence space. Write markdown in this
repository, publish to Confluence Cloud with a single command. The publisher
enforces scope, style, and update-safety gates before anything reaches the wiki.

- **Wiki:** https://infinitium.atlassian.net/wiki (space `NPG`)
- **Boundary:** writes are allowed ONLY under folder `4125949974`
  ("Local Toolkit Setup") or its descendants
- **Runtime:** bash + curl + python3 stdlib. Zero pip installs.

## Quickstart

### 1. Environment

```bash
# API token — create at https://id.atlassian.com/manage-profile/security/api-tokens
export CONFLUENCE_TOKEN='<token>'        # required for anything touching the API
export CONFLUENCE_EMAIL='rizki.rachman@infinitium.com'   # this is the default
# export CONFLUENCE_BASE_URL='https://infinitium.atlassian.net/wiki'  # default
```

The token lives in your shell environment only. The publisher never echoes it,
logs it, or writes it to any file.

### 2. Discover the folder tree

```bash
./publish.sh init
```

Prints everything under folder `4125949974` with content ids:

```
Local Toolkit Setup (4125949974)  [root folder]
├── CI/CD (4157603973)  [folder]
│   └── Some Page (4157603999)  [page]
└── ...
```

`init` also caches ancestry into `mappings.json`, so later dry-runs for those
parents work offline. Pick a folder id and use it as your page's `parent`.

### 3. Author a page

Copy a starter from `templates/`, or create a file with frontmatter:

```markdown
---
title: Docker Setup with Rancher Desktop
parent: 4125949974
confluence-id:             # absent or empty → CREATE; set → UPDATE
---

Page body in markdown. See context/wiki-style.md for the rules.
```

- Filenames: kebab-case. Titles: Title Case, no dates.
- `confluence-id` maps the file to its Confluence page (see `mappings.json`,
  where the publisher also records versions).
- After the first publish, the command prints the new id — paste it into the
  frontmatter so future runs UPDATE instead of CREATE.

### 4. Dry-run, then publish

```bash
./publish.sh NPG/local-toolkit-setup/my-page.md            # dry-run (default)
./publish.sh NPG/local-toolkit-setup/my-page.md --publish  # write to Confluence
```

## Gates (in order)

| # | Gate | Dry-run | `--publish` |
| --- | --- | --- | --- |
| 1 | Frontmatter valid (`title` + `parent` present) | required | required |
| 2 | Scope guard: parent inside `4125949974` subtree | cached ancestry accepted | live API check, always |
| 3 | Humanizer lint | HARD findings warn | HARD findings block; SOFT findings warn only |
| 4 | Plan + storage-format preview (first 50 lines) | printed | printed, then write |
| 5 | Version check at write time | recorded (`pending_version`) | enforced: payload uses `current + 1`; aborts on change |

Lint rules — HARD (block `--publish`): em dashes beyond 2 per 100 words;
"not just X but Y"; promotional wording ("seamless", "robust", "cutting-edge",
"leverage" as a verb). SOFT (warn only): more than 3 "X, Y and Z" triples per
page; more than 5 passive-voice candidates per page.

## Boundary warning

> **HARD BOUNDARY:** the publisher refuses (exit 3, zero writes) any page whose
> `parent` is outside folder `4125949974` "Local Toolkit Setup" or its
> descendants. Before any write it calls
> `GET /rest/api/content/{parentId}?expand=ancestors` and walks the ancestor
> chain; the root id must appear. If the parent id does not exist or the API
> cannot be reached, the publisher fails closed. Never repoint `root_folder_id`
> in `mappings.json` without team agreement.

## Commands

| Command | Effect |
| --- | --- |
| `./publish.sh <file.md>` | Dry-run: gates, plan, storage preview. No writes. |
| `./publish.sh <file.md> --publish` | All gates, then CREATE/UPDATE via API. |
| `./publish.sh init` | Fetch + print folder tree under the boundary root; cache ancestry. |
| `bash tests/run.sh` | Offline assert-based test suite (converter, frontmatter, lint, scope). |
| `bash tests/smoke.sh` | Read-only API smoke test; auto-skips without `CONFLUENCE_TOKEN`. |

## Templates

| Template | Purpose | Mandatory sections |
| --- | --- | --- |
| `templates/setup-guideline.md` | Environment/tooling setup | ends with `Verification` |
| `templates/how-to.md` | Task instructions, max 7 steps (split beyond that) | `Verification` |
| `templates/runbook.md` | Operational procedure | ends with `Rollback` |
| `templates/adr.md` | Architecture decision record | `Status`, `Context`, `Decision`, `Consequences` |

Authoring instructions inside templates are HTML comments; the converter strips
them on publish. Style rules: `context/wiki-style.md`. Labels
(`npg-setup`, `npg-runbook`, `npg-adr`, `npg-how-to`) are applied in Confluence
after the first publish — labels/attachments are out of scope for the publisher.

## mappings.json

Registry kept in the repo (committed intentionally, no secrets):

| Key | Meaning |
| --- | --- |
| `root_folder_id` | Publish boundary root: `4125949974` |
| `known_folders` | Folder id → title/type/parent (seeded; `init` extends) |
| `scope_cache` | Verified ancestor chains per parent id (written by the scope gate and `init`) |
| `discovered_pages` | Page id → title/parent (written by `init`) |
| `pages` | Markdown file path → confluence-id, title, published/pending versions |

## Converter scope

`lib/convert.sh` turns markdown into Confluence storage XHTML: headings h1–h6,
bold/italic/strikethrough, inline code, fenced code blocks (code macro with
language), bullet/ordered lists (max 3 nesting levels), GFM tables with
alignment, blockquotes, links/autolinks, horizontal rules, paragraphs, hard
line breaks. Text nodes are HTML-escaped. Images are skipped with a warning
comment (attachments out of scope). Unknown constructs render as escaped plain
text plus an HTML comment note — nothing is silently dropped.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `HTTP 401` | Token missing, expired, or wrong email pairing | Regenerate the token at id.atlassian.com, re-export `CONFLUENCE_TOKEN`, confirm `CONFLUENCE_EMAIL` matches the token's account |
| `exit 6` version conflict / "changed since dry-run" | The page changed on Confluence between your dry-run and `--publish`, or concurrently mid-write | Re-run the dry-run, review the new preview, then `--publish` again; nothing was written by the aborted run |
| `exit 3` scope refusal | `parent` sits outside the `4125949974` subtree | Run `./publish.sh init`, pick an in-scope folder id, fix the frontmatter `parent` |
| `exit 3` "CONFLUENCE_TOKEN is unset (fail-closed)" | Dry-run with an uncached parent, or publish without a token | Run `./publish.sh init` once with a token (caches ancestry), or export `CONFLUENCE_TOKEN` |
| `HTTP 404` on update | Stale `confluence-id` (page deleted/moved) | Verify the id via `./publish.sh init`, update or clear the frontmatter field |
| `exit 5` hard lint | Em dashes / "not just X but Y" / promo wording in the body | Edit the flagged text; SOFT findings (triples, passive voice) are advisory |
| Empty page content error | Body has no convertible content | Add content below the frontmatter closing `---` |

## Exit codes

`0` success · `2` usage · `3` scope refusal / fail-closed · `4` frontmatter ·
`5` hard lint · `6` version conflict · `7` API/network · `8` missing tool or token
