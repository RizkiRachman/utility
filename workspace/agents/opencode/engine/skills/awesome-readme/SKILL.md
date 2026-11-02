---
name: awesome-readme
description: Write excellent READMEs following the awesome-readme standard - badges, clear description, screenshots, TOC, quick start, config tables, examples, architecture notes. Use when creating or updating README.md, docs, or any project-facing documentation.
license: MIT
compatibility: opencode
tags:
  - documentation
  - readme
  - awesome-readme
---

# Awesome README

Standard for project READMEs, distilled from [awesome-readme](https://github.com/matiassingers/awesome-readme) (curated list of exemplary READMEs).

## When to Use

- Creating a new README.md
- Rewriting or restructuring existing docs
- Reviewing a README before shipping

## Required Elements (in order)

| # | Element | Rule |
|---|---------|------|
| 1 | **Title + one-liner** | What it is in <= 120 chars. No marketing fluff. |
| 2 | **Badges** | Only truthful ones (version, platform, status). 3-5 max, top center. |
| 3 | **Description** | 2-4 sentences: problem, what this does, why it exists. |
| 4 | **Screenshot / GIF** | If the project has a UI, show it. Above the fold. |
| 5 | **Table of Contents** | Required when README > ~150 lines. Anchor links. |
| 6 | **Quick Start** | Copy-pasteable commands that WORK. Minimum path to running. |
| 7 | **Configuration** | Tables for env vars / config files. Name, required, default, description. |
| 8 | **Examples** | Real usage, not pseudocode. |
| 9 | **Project Structure** | Annotated tree for repos with >5 meaningful dirs. |
| 10 | **Architecture** | Diagram (mermaid renders on GitHub) when >2 moving parts. Link ARCHITECTURE.md if separate. |
| 11 | **FAQ / Troubleshooting** | Top 3-5 real questions, not hypotheticals. |
| 12 | **Contributing / License** | Even if "internal - no external contributions". |

## Style Rules

- Scannable: headers, tables, bullets. No walls of text.
- Every command in a fenced code block with language tag.
- Tables over prose for config/envars.
- Absolute minimum viable quick start; advanced setup goes in its own section.
- No stale badges, no TODO placeholders, no lorem ipsum.
- Emoji: sparingly, section headers at most. Never in code blocks.
- Link out for depth (docs/, ARCHITECTURE.md, wiki) instead of bloating the README.

## Pre-Ship Checklist

- [ ] Quick start tested fresh (copy-paste works on clean checkout)
- [ ] All config/env documented in tables
- [ ] TOC anchors resolve
- [ ] Screenshots current
- [ ] No secrets or internal hostnames in examples

## Reference

- Curated exemplars: https://github.com/matiassingers/awesome-readme
- Architecture doc pattern: https://github.com/evanw/esbuild/blob/main/docs/architecture.md
