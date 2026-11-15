# PR: Production hardening final - artifact digests, enforced security preflights, session seeding, opt-in socket proxy

Branch: fix/production-hardening-final (3 commits off main post-PR-#1; patches in .analysis/patches-v2/)
Evidence base: .analysis/ANALYSIS-V2.md (post-merge re-verification) - this PR closes every remaining OPEN/PARTIAL finding.

## Summary

PR #1 closed the four launch blockers. This PR closes the rest of the register: the hash-free offline store (S3, highest remaining risk), the certs allowlist gate (S2), deployment-mode password enforcement (S5), session-root seeding (D16), the missing opencode healthcheck (P3-16), an opt-in docker socket proxy (S1), and the cert-detector unit tests (P3-15). Everything is mechanism-first: nothing speculative, no invented data, no secrets.

## Verified vs mechanism-only (honest statement)

- VERIFIED BY EXECUTION: digest verification paths (missing-file FATAL, mismatch FATAL, clean OK - all three exercised offline), certs allowlist check (runs green), cert-detector unit tests (4/4 pass on synthetic openssl certs), entrypoint syntax and seeding logic, compose YAML edits, CI step presence, loop-validate ALL-PASS, validate-contract score 85.
- MECHANISM-ONLY UNTIL FIRST MAINTAINER RUN: actual artifact digests. No digests are invented in this PR (there is no artifact store content in the clone and CI must not fetch). Run once with network: sh populate-preinstall.sh --update-digests - it computes and commits digests.sha256; from then on every populate run and the Docker build (--verify-digests) fail hard on mismatch. The Dockerfile wiring to call --verify-digests at build time is intentionally NOT added in this PR to avoid failing all existing builds before the first digest run; it is a two-line follow-up once digests.sha256 is populated (documented in the README security note).

## Changes mapped to findings

| Finding | File(s) | Change |
|---|---|---|
| S3 / P2-9 | populate-preinstall.sh, pre-install/digests.sha256 (new, tracked), opencode README | sha256 digest layer: fetch-time verify (recorded=enforced, unrecorded=warn), --verify-digests offline gate, --update-digests maintainer path, lock file records digests-file + enforcement state; README policy note |
| S2 / P2-13 | certs/check-certs.sh (new), certs-allowlist.txt (new, tracked), validate.yml | CI step rejects any .crt not matching the tracked allowlist; un-ignored from the certs gitignore (the gate files must be reviewed, not hidden) |
| P3-15 | certs/test-detect-zscaler.sh (new, tracked) | 4 unit tests for the detector sourced mode: zscaler root extraction, prefix, non-zscaler rejection, fingerprint dedupe vs manual certs. 4/4 pass offline |
| S5 / P2-11 | entrypoint.sh, compose env | OPENCODE_DEPLOY_MODE=production fails boot unless OPENCODE_SERVER_PASSWORD set or OPENCODE_BIND_LOCALHOST=1; dev default unchanged; compose passes both through |
| D16 / P2-12 | entrypoint.sh, engine README | boot seeds session/ (contract.json from engine template, state.md example, archive dir; idempotent; OPENCODE_SESSION_DIR override); path-jail alignment note under Where State Lives |
| P3-16 | docker-compose.example.yaml | opencode service healthcheck (curl :4096, 30s interval, 30s start period) |
| S1 / P2-10 | docker-compose.socket-proxy.yaml (new) | opt-in filtered docker API profile (CONTAINERS/IMAGES/NETWORKS, no EXEC/VOLUMES) with !override volumes dropping the host socket mount; base compose unchanged; pin note via DOCKER_SOCKET_PROXY_IMAGE |
| cosmetic merge regression | docker-compose.example.yaml | pin-strategy args comment restored; redundant dockerfile: key removed (additional_contexts preinstall intact) |

## Verification evidence

- bash -n sweep: all engine scripts, entrypoint.sh, both new certs scripts - clean; sh -n on populate (dash-compatible)
- populate --verify-digests: missing-file FATAL + exit 1; bogus-digest mismatch FATAL + exit 1; correct-digest OK - zero resolver/network lines in verify mode (offline proven)
- check-certs.sh: green (0 files, allowlist enforced path exercised); cert-detector tests: 4/4 PASS
- engine gates via the deployed allowlist: loop-validate ALL-PASS (json, bash-syntax, cross-references); validate-contract on template+rules: score 85, writing order correct
- jq -e on all touched JSON; git diff --check clean; working tree clean after commits
- digests.sha256 and the certs gate files un-ignored in their .gitignores - the integrity anchor must be reviewed in PRs, not hidden

## Review checklist

- [ ] S3: accept mechanism-first (no invented digests) and the deferred Dockerfile --verify-digests wiring until the first --update-digests run
- [ ] S5: confirm dev-default is acceptable for this stack (production opt-in documented)
- [ ] S1: confirm the socket-proxy opt-in surface (tecnativa image; pin via DOCKER_SOCKET_PROXY_IMAGE before prod; compose v2.24+ for !override)
- [ ] S2: confirm the certs allowlist seeding (zscaler-autodetected-*.crt only) and the un-ignore approach
- [ ] D16: confirm the seeded session path (/home/node/workspace/session, OPENCODE_SESSION_DIR override) matches operator expectations
- [ ] No secrets anywhere (checked: only empty env defaults and placeholders)

## Security review note

Authored under a depth-limited session: cross-model reviewer spawn was impossible from inside (platform limit, marked cross_model_degraded in the orchestration envelope). The diff is ready for independent cross-model review at the top level; security-sensitive areas: populate digest layer, entrypoint preflights, certs gate, compose override.

## Independent review round (post-PR-#2-open)

An independent cross-model review round ran on the open PR (security verdict: BLOCK, quality verdict: RETRY). Findings converged with this branch and were fixed in place on fix/production-hardening-final:

- Digest gate integrity: pin COUNT (non-comment entries) replaces the [ -s ] check - a comments-only manifest can no longer print verification OK with zero pins (fail-closed); verify_all_digests is wired into the populate run end AND the Dockerfile build gate AND the validate.yml CI step; verify mode reverse-sweeps unpinned store files; mismatched artifacts are quarantined out of the Dockerfile globs; --update-digests regenerates the full manifest (sorted, deduped) so version bumps cannot leave stale pins; versions.lock records the pin count.
- Socket proxy honesty: the overlay now carries the docker.sock mount itself (the overlay is self-contained), a dedicated internal network, depends_on, PING/VERSION capability gates, and a header that says what it does and does not do. DEFERRED: the proxy image is referenced by tag with an explicit TODO(digest) comment - registry access was denied in the authoring session; pin by digest before production (commands in the file header).
- BIND_LOCALHOST: implemented - production + BIND_LOCALHOST=1 binds the serve/listen host to loopback instead of merely documenting intent; strict DEPLOY_MODE validation (unknown values fail fast).
- Healthcheck: code-based probe (<5xx healthy) so the 401 basic-auth challenge is not a false red; start_period 90s; the standalone dev compose notes its intentionally minimal parity.
- Seeding resilience: session seeding warns and skips (no crash loop) when the workspace is unwritable; archive/state heal path added.
- Certs: sync-certs.sh invokes check-certs.sh at the end (a non-allowlisted cert after sync fails the run); check-certs.sh warns on missing mirror dirs instead of failing.

Re-verification delta (second review round): fixed the socket-proxy image org typo (`tecnatica` -> `tecnativa`, 4 places), made the certs allowlist check enforcing at the populate call site (sync best-effort, check enforcing via `CERTS_GATE_REQUIRED`), replaced the reverse-sweep regex with an exact match (`+`-in-name regression covered), made the socket-proxy shipped default read-only (POST/ALLOW_RESTARTS = 0, create-capable profile commented opt-in), legacy-builder-safe `.dockerignore`, verify gate now runs before versions.lock, CI wires the cert detector tests + extended bash -n sweep, and a dangling-symlink guard in entrypoint seeding. Full map with file:line evidence: `.analysis/ANALYSIS-V3.md` Appendix 2.

Remaining deferrals (explicit): socket-proxy image digest pin (TODO in file), TOFU first-fetch window (documented; inherent to a bootstrap digest store), full digest population (needs one networked --update-digests run).
