---
name: context-standards
version: 1.0.0
description: Discover and load project-specific pattern and standards files (context/*.md) before implementation, review, or design work. Carries binding style rules into each agent's output. Use when working in a target project that defines context files.
compatibility: opencode claude-code
---

# Context Standards: Load Project Pattern Rules Before Work

Protocol adapted from OpenAgentsControl's context system (darrenhinde/OpenAgentsControl, MIT), re-implemented as a zero-dependency skill. This is an idea adoption, not a vendored copy: no OAC code ships here and the protocol below is written for this engine's contract flow.

## Protocol

1. **DISCOVER**: Look for a `context/` directory at the target project root (the project being worked on, i.e. the session's working directory). Collect `context/*.md` files. Names are non-prescriptive; common ones: `standards.md`, `api-patterns.md`, `testing.md`, plus an optional `examples/` subdirectory.
2. **PRIORITIZE**: Load order:
   - Files the user or the contract names explicitly (`session/contract.json` `scope.*` fields).
   - Standards and security files (for example `standards.md`, `security.md`).
   - Topic files whose names match the current task keywords.
3. **LOAD**: Only what is relevant to the current task (lazy loading). Treat every rule in a loaded file as a BINDING style constraint during implementation, review, and design output.
4. **CARRY-FORWARD**: At the top of implementation summaries and quality reviews, list the standards files loaded, or state "no project standards found". This makes compliance inspectable downstream.
5. **GRACEFUL**: If `context/` is absent, say so and proceed with generic capability. Never invent standards. Never block work on missing standards.
6. **SIZE GUIDANCE** (advisory): keep context files under ~200 lines each; split by topic when a file grows past that.

## When To Load

- Before writing code in a project that defines `context/` files.
- Before reviewing code from such a project (verify the developer side loaded them).
- Before architecture or design output for such a project.

## Non-Goals

- The engine ships no default standards; every rule comes from the target project.
- No tooling, no dependencies: this is a read-and-apply protocol, enforced by agent discipline and the cross-reference wiring check.
