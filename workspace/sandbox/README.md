# Sandbox

Session-scoped playground for every agent. Scratch work lives here, one folder per live session, and nothing inside is committed.

<p>
  <img alt="status: active" src="https://img.shields.io/badge/status-active-4a8ad6">
  <img alt="scope: all agents" src="https://img.shields.io/badge/scope-all%20agents-2d3142">
  <img alt="tracked: skeleton only" src="https://img.shields.io/badge/tracked-skeleton%20only-f08a59">
</p>

## Table of Contents

1. [Why this exists](#why-this-exists)
2. [Quick start](#quick-start)
3. [Rules](#rules)
4. [Naming](#naming)
5. [Layout](#layout)
6. [Lifecycle](#lifecycle)
7. [Ports](#ports)
8. [What is tracked](#what-is-tracked)
9. [FAQ](#faq)
10. [Enforcement](#enforcement)
11. [License](#license)

## Why this exists

Agents need somewhere to run probes, clone a repo, render a page, or keep a throwaway build. Without a shared convention that work lands in repo paths, in `/tmp`, or on top of another session's files, and the friction shows up as overwritten artifacts, colliding dev-server ports, secrets in git, and a repo full of debris.

This folder fixes the location. The rules below fix the collisions.

## Quick start

```bash
cd /home/node/workspace

slug=opencode-optimizer          # your OpenCode session title, slugified
mkdir -p sandbox/$slug
printf '# %s\n\nSession scratch space.\n' "$slug" > sandbox/$slug/README.md
```

Write everything for this session under `sandbox/$slug/`. Delete the folder when the session ends, unless the user asks to keep it.

## Rules

| # | Rule | Level |
|---|------|-------|
| 1 | One folder per live session: `sandbox/<session-slug>/` | MUST |
| 2 | Write only inside your own session folder. Other sessions' folders are read-only | MUST |
| 3 | Never delete another session's folder without explicit user approval | MUST |
| 4 | Never write at `sandbox/` root; it holds the tracked skeleton only | MUST |
| 5 | Nothing in the sandbox is committed. It is gitignored by design | MUST |
| 6 | No secrets, tokens, credentials, certificates, or customer data. Use environment variables | NEVER |
| 7 | Promote durable output to its real home before the session ends. The sandbox is disposable | MUST |
| 8 | Bind dev servers to `127.0.0.1`, use a port in 4100-4999, stop them before finishing | MUST |
| 9 | Stay under 200 MB per session folder and 7 days since last write | SHOULD |
| 10 | Log long-running processes to `sandbox/<slug>/logs/` and leave no daemon behind | MUST |

The full enforcement text ships with the engine: `agent.md` section 6 (Sandbox) and `rules.json` at `enforcement.sandbox`.

## Naming

The folder name is the session title, lowercased, with spaces and punctuation collapsed:

```
opencode optimizer   ->  opencode-optimizer
Next.js port         ->  nextjs-port
fix auth bug (2)     ->  fix-auth-bug-2
```

Rules for the slug: lowercase ASCII, `[a-z0-9-]` only, no leading or trailing hyphen, 40 characters maximum.

If two live sessions slugify to the same name, append a 4-character prefix of the session ID: `opencode-optimizer-a3f2`.

## Layout

```text
sandbox/
├── README.md               # tracked   this file
├── .gitignore              # tracked   ignores everything else
├── .gitkeep                # tracked   keeps the folder in the tree
├── opencode-optimizer/     # ignored   current session
│   ├── README.md           #           what this session left behind
│   └── ...                 #           mock-ui, visual-explainer-test, probes
└── <other-session>/        # ignored   read-only to you
```

## Lifecycle

1. **Create** at session start, named from the session title.
2. **Work**: scripts, clones, screenshots, throwaway builds.
3. **Promote**: move anything worth keeping into the repo or `documentation/`.
4. **Prune**: delete the folder, or run the 7-day check below and remove stale folders. No automated sweeper exists yet; the TTL is a policy, not a cron job.

```bash
# what is taking space
du -sh sandbox/*/ 2>/dev/null | sort -h

# session folders untouched for more than 7 days
find sandbox -mindepth 1 -maxdepth 1 -type d -mtime +7

# remove one (yours)
rm -rf sandbox/opencode-optimizer
```

## Ports

Two sessions starting a dev server on 3000 is the most common collision. Derive a stable port from the slug:

```bash
slug=opencode-optimizer
port=$((4100 + $(printf '%s' "$slug" | cksum | cut -d' ' -f1) % 900))
echo "port $port"
```

Range 4100-4999 stays clear of OpenCode (4096), OpenUI (3000), and Gitea (3300).

## What is tracked

| Path | Tracked | Why |
|---|---|---|
| `sandbox/README.md` | yes | The rules live with the folder |
| `sandbox/.gitignore` | yes | Keeps the ignore policy in the repo |
| `sandbox/.gitkeep` | yes | Keeps the empty folder in the tree |
| `sandbox/<session>/` | no | Session debris, never shared |

Same pattern as [`certs/`](../certs/): ignore everything, negate the skeleton. Nothing is pushed except the three files above.

## FAQ

**Can I keep a deliverable here?** No. Move it to its project folder first. The sandbox can be deleted at any time without notice.

**Can I read another session's folder?** Yes, read-only. Do not edit or delete it; ask the user if you need a change.

**Why is my file missing from git?** By design. `sandbox/.gitignore` ignores every path except the skeleton.

**Where do test credentials go?** Nowhere in the sandbox. Use environment variables, or a `.env` file that is already gitignored in the project that needs it.

**A server is still running.** Find it, then stop it: `lsof -i :4100-4999` shows the owner.

## Enforcement

| Layer | File | What it enforces |
|---|---|---|
| Global instructions | `agents/opencode/engine/agent.md` section 6 | Every agent reads it at session start |
| Machine-readable rules | `agents/opencode/engine/rules/rules.json` `enforcement.sandbox` | Path, naming, scope, quota, ports |
| Agent permissions | `agents/opencode/engine/agents/*.md` | Writer agents carry the local clause |
| Review gate | `quality-analyst` (REVIEW state) | Treats a write outside the session folder as a process finding |

Scope is enforced by instructions and review, not by an automated checker: a write to another session's folder is a process violation an agent must report, and a reviewer must flag.

## License

Internal. No external contributions.
