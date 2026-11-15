# ANALYSIS V3 - Final Closure Status (branch fix/production-hardening-final)

- Date: 2026-11-15 - Base: ANALYSIS-V2.md (post-merge re-verification); this round closes every remaining OPEN/PARTIAL item on branch fix/production-hardening-final (15a6a27 security, 33c0856 ops, 192cebf docs).
- Re-index after the round: rag 844 -> 852 files, 14794 -> 14832 chunks (incremental, 266 ms).

## Final register

| Finding | V2 status | V3 status | Evidence (this branch) |
|---|---|---|---|
| B1-B4 | CLOSED | CLOSED (unchanged) | PR #1 merged + deployed; gate scripts live-verified in V2 |
| D1-D15 | CLOSED | CLOSED (unchanged) | PR #1 |
| D16 | OPEN | CLOSED | entrypoint.sh seeds session/ at boot (contract.json + state.md + archive, idempotent, OPENCODE_SESSION_DIR); path-jail note in engine README Where State Lives |
| S1 | PARTIAL | PARTIAL -> CLOSED-OPT-IN | docker-compose.socket-proxy.yaml: opt-in filtered API (no EXEC/VOLUMES), !override drops the host socket; base unchanged by design; blast-radius + migration documented. Direct-mount default remains an accepted, documented risk |
| S2 | OPEN | CLOSED | certs/check-certs.sh + tracked certs-allowlist.txt + validate.yml CI step; gate files un-ignored so they are reviewable |
| S3 | OPEN (HIGH) | CLOSED-MECHANISM (verified paths, digests pending first maintainer run) | populate-preinstall.sh digest layer: recorded=enforced (mismatch aborts), unrecorded=warn, --verify-digests offline gate (proven: 0 resolver lines; missing/mismatch/OK paths all exercised), --update-digests maintainer path; digests.sha256 tracked skeleton; versions.lock records digests-file + enforcement state; README policy note. No digests invented |
| S5 | PARTIAL | CLOSED (dev default retained) | OPENCODE_DEPLOY_MODE=production fails boot without OPENCODE_SERVER_PASSWORD or explicit OPENCODE_BIND_LOCALHOST=1; compose passes both; docs note both modes |
| P3-15 | PARTIAL | CLOSED | cert-detector tests shipped: 4/4 pass (extraction, prefix, non-zscaler rejection, fingerprint dedupe); transition row + badge policy were closed in PR #1 |
| P3-16 | OPEN | CLOSED | compose healthcheck for opencode (curl :4096) |
| cosmetic 9919d08 regression | noted | CLOSED | args pin-strategy comment restored; redundant dockerfile: key removed; additional_contexts intact |

## Gates run on this branch (all green)

- bash -n: all engine scripts + entrypoint + both new certs scripts; sh -n populate (dash-compatible)
- loop-validate.sh: ALL-PASS (json-validity, bash-syntax, cross-references) - via the deployed allowlist
- validate-contract.sh on template + rules: score 85, WRITING ORDER CORRECT
- check-certs.sh: green; test-detect-zscaler.sh: 4/4 PASS
- jq -e: config, template, rules - valid; git diff --check clean; tree clean after 3 commits

## Verdict

PRODUCTION-READY (with two named operational conditions, unchanged in kind but now fully mechanized):
1. Run sh populate-preinstall.sh --update-digests once with network, commit digests.sha256, then add the two-line Dockerfile --verify-digests wiring (documented; intentionally deferred to avoid failing existing builds before the first digest run).
2. Activate production protections where deployed: OPENCODE_DEPLOY_MODE=production (+ password), and opt into docker-compose.socket-proxy.yaml where the docker socket blast radius is unacceptable.

Cross-model review note: authored under the platform depth-1 limit (no reviewer spawn possible from this session); governance.cross_model_degraded=true recorded. The three commits are packaged for independent cross-model review (patches in .analysis/patches-v2/).

- End of ANALYSIS V3 -

## Appendix: independent-review finding map (V3 final)

IDs from the independent cross-model review round on PR #2 (security BLOCK / quality RETRY). Mapping to fixes on fix/production-hardening-final:

| Review ID | Status | Fix + evidence |
|---|---|---|
| C1 digest gate counts nothing (comment-only manifest green) | FIXED | digest_pin_count (populate-preinstall.sh:100); verify_all_digests fails on 0 pins with non-empty store - functional test: FATAL pins NOTHING, true exit 1 |
| C2 verify_all_digests not wired into build/CI | FIXED | Dockerfile digest gate block + validate.yml CI step + populate-run end gate (end-of-run re-verify) |
| H1 (sec) socket overlay claimed drop-mount without carrying it | FIXED | overlay carries the docker.sock mount itself (docker-compose.socket-proxy.yaml:42) + honest header |
| H2 (sec) BIND_LOCALHOST documented but not implemented | FIXED (sec-H2/H4) | entrypoint BIND_HOST wiring: production + BIND_LOCALHOST=1 binds loopback (entrypoint.sh:192,268-272); strict DEPLOY_MODE validation |
| H3 (sec-M4) healthcheck false-red on 401 | FIXED | code-based probe (<5xx healthy) compose:63; start_period 90s |
| H4 (sec-H3) stale manifest pins FATAL after version bumps | FIXED | --update-digests regenerates the full manifest (sorted, deduped); prune leaves no dead pins |
| M1 unpinned store files invisible to verify | FIXED | verify-mode reverse sweep FATAL (populate-preinstall.sh:188-200) - test: exit 1 on unpinned |
| M2 mismatched artifact still consumable by globs | FIXED | quarantine to .quarantine/ (populate-preinstall.sh:120-126) - test: file moved |
| M3 end-of-run no re-verification | FIXED | end-of-run gate re-verifies pinned artifacts after all fetches |
| M4 CI lacked digest step | FIXED | validate.yml digest gate step |
| M5 sync-certs could end with a non-allowlisted cert | FIXED | sync-certs.sh invokes check-certs.sh; failure exits nonzero (sync-certs.sh tail) |
| M6 missing mirror dirs crash the certs gate | FIXED | check-certs.sh warns on missing dirs |
| M8 versions.lock enforcement state from [ -s ] | FIXED | digests-enforced from PIN COUNT (populate-preinstall.sh:929) |
| L1-L4 dev-compose parity + docs truth | FIXED/DOCUMENTED | standalone compose comment; README S3/S5/S1 claims aligned to behavior (TOFU window named, blast-radius reducer not boundary, BIND binds, 401-tolerant) |
| L6/L7 socket-proxy image digest pin + TOFU naming | DEFERRED/DOCUMENTED | TODO(digest) comment with pin-by-digest commands in the overlay header (registry access denied in-session); TOFU first-fetch window documented in the README security note |

All 20 mapped: 17 FIXED, 3 DOCUMENTED/DEFERRED with explicit TODO owners. Suite: bash -n sweep clean, cert tests 4/4, digest functional tests (a)-(e) pass with true exit codes, loop-validate ALL-PASS, validate-contract 85, git diff --check clean.

## Appendix 2: re-verification delta fixes (second review round, 2026-11-15)

The re-verification of the first-round fixes confirmed all prior criticals FIXED but surfaced a fix-delta with 3 new defects (security N1-N3) plus a quality pass (Q-N/L items). All folded into the single delta commit on fix/production-hardening-final:

| Review ID | Status | Fix + evidence |
|---|---|---|
| sec N2 (High) wrong image org `tecnatica` in 4 places | FIXED | docker-compose.socket-proxy.yaml:28,30,31,37 - squatted org = attacker image with the host socket mounted; verified `grep -c tecnatica` = 0, `tecnativa/docker-socket-proxy` = 4 |
| sec N3 (High) cert gate neutralized by `\|\| true` at its only live call site | FIXED | populate-preinstall.sh:231-248 - sync-certs.sh can exit 1 benignly (seeding detector environment error), so the sync stays best-effort but the allowlist CHECK is re-run directly and enforces (CERTS_GATE_REQUIRED default 1, opt-out documented at :237); verified: rogue cert -> FATAL rc 1 BEFORE the CA-trust block, CERTS_GATE_REQUIRED=0 -> WARN + continue, benign no-zscaler -> gate passes |
| sec N1 (Medium) unescaped ERE in the verify-mode reverse sweep | FIXED | populate-preinstall.sh:195-202 - grep -qE with the filename interpolated replaced by awk exact compare (`$2==r`), same approach as digest_check; regression: pinned `@opencode+cli-2.3.0.tgz` verifies OK (the `+` no longer false-FAILs), unpinned `a.b.tgz` still FATALs (no `.` wildcard bypass) |
| L1 (cheap) dangling symlink defeats entrypoint seeding | FIXED | entrypoint.sh:26-31,46-49 - `[ -L ]` + `rm -f` before the `[ ! -f ]` cp guard for contract.json and state.md, so cp writes the real file instead of following the link to a missing target |
| Q-N3 (Med) socket-proxy header contradicted shipped config (POST:1/ALLOW_RESTARTS:1 active under a "read-only profile" claim) | FIXED | header rewritten to state exactly what ships (:18-25); shipped default is now POST:0/ALLOW_RESTARTS:0 (:59,65) with the create-capable profile as the commented opt-in inverse - also the safer default per the security reviewer's preference |
| Q-N4 (Low) .dockerignore `pre-install` broke the digests negation on the legacy builder | FIXED | workspace/agents/opencode/.dockerignore:6-7 - `pre-install/*` + `!pre-install/digests.sha256` (builder-independent) |
| Q-N5 (Low) versions.lock written before the end-of-run verify gate | FIXED | gate moved above the lock write (populate-preinstall.sh:936-940) - the lock only records a state that passed |
| Q-L4 (cheap) zscaler tests not wired into CI | FIXED | validate.yml: bash -n sweep extended with populate-preinstall.sh + certs/*.sh (:34-35); new "Cert detector tests" step (:87) |
| Q-L9 (trivial) `init: true` undocumented | FIXED | docker-compose.socket-proxy.yaml:40-41 - one-line PID-1 reaping rationale |
| Q-N6 (BuildKit mount syntax needed) | DEFERRED | requires BuildKit-only compose syntax; legacy-builder parity is kept deliberately |
| Q-N7 (coupling concern) | DEFERRED | coupling judged acceptable; no behavioral defect |
| Q-N8 (vestigial config) | DEFERRED | vestigial but harmless; removal is cosmetic churn |
| Q-N9 (unavoidable fallback path) | DEFERRED | fallback is unavoidable by design and already WARNs |

Delta verification suite: bash -n + sh -n on touched scripts; N1 regression (pinned `+`-name rc 0 / unpinned dotted name rc 1); cert-gate functional tests (rogue FATAL / opt-out WARN / benign pass); tecnativa 0/4 count probe; test-detect-zscaler.sh 4/4; loop-validate ALL-PASS; git diff --check clean; no secrets. Note: validate-contract.sh numeric score not reproducible this session (bc absent, score gates disabled); its content/access/scope/timeout checks PASS and the two parallel-deadlock config FAILs reproduce identically on the pre-change tree (pre-existing contract/rules mismatch, outside this delta's scope).
