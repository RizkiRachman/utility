# Eval Tasks

Fixed, deterministic evaluation tasks for the workflow-state engine (R2-15).
Each task is a thin wrapper around an existing quality gate so the same
checks that ship code also measure it. Run the full set before a release
and read the results next to the month-over-month trend in
`session/eval-report.md` (produced by `metrics-aggregator.sh --mode monthly`
from the `auto-score.sh` JSONL ledger).

## Tasks

| Task | Verifies | Underlying gate |
|---|---|---|
| T1-validate-contract.sh | Contract template validates at threshold | `scripts/validate-contract.sh --score` |
| T2-cross-refs.sh | All cross-references resolve | `scripts/check-cross-references.sh` |
| T3-doc-style.sh | Docs pass the style gate | `scripts/check-doc-style.sh` |
| T4-score-calibration.sh | Verdict boundaries, tier1_only cap, permission signal handling | `auto-score.sh` thresholds + score corpus and audit fixture |
| T5-controller-integration.sh | Controller policy, request-bound delegation loops, evidence, completion, concurrency | `workflow-controller.sh` + `loop-guard.sh` + `transition.sh` |
| T6-judge-coverage.sh | Malformed ledger rows never count as judge evidence | `judge-coverage.sh` |
| T7-telemetry.sh | Per-phase timing/token aggregation excludes orphaned runs | `phase-telemetry.sh` |
| T8-context-provenance.sh | Context records carry source, commit, timestamp, evidence status | `context-provenance.sh` |
| T9-judge-agreement.sh | Labeled aggregation corpus: verdict math, false-pass/block, jitter stability (fixtures only, not real-judge agreement) | `fixtures/judge-labels.jsonl` |
| T10-blocked-sla.sh | BLOCKED TTL stamped on transition and enforced against rules | `blocked-sla.sh` + `transition.sh` |
| T11-merge-shards.sh | Parallel shard merge: conflict abort, path safety, rollback | `merge-shards.sh` |
| T12-shell-policy.sh | Shell writes to policy artifacts denied; reads/ordinary writes audited | `workflow-controller.sh` |
| T13-prompt-budget.sh | Duplicate instruction text measured and gated; shared pointer required | `prompt-budget.sh` + `shared/protocol.md` |
| T14-plugin-registration.sh | Guard plugin registration and deployed files verified | `check-plugin-registration.sh` |
| T15-enforcement-gates.sh | Full schema gate, edge-specific evidence, BLOCKED manual exit, completion phases | `workflow-controller.sh` + `transition.sh` |
| T16-shard-recovery.sh | Interruption rollback and journal-based recovery of shard merges | `merge-shards.sh` |
| T17-telemetry-coverage.sh | Required phases instrumented per task class | `phase-telemetry.sh` |
| T18-learning-impact.sh | Learning reuse recorded and reported across tasks | `learning-record.sh` |
| T19-failure-loop.sh | Typed failure-loop strategy matrix exercised end to end | `failure-loop.sh` |
| T20-doc-hygiene.sh | No em dashes in engine markdown; advertised counts match tree/config | `grep` + `jq` |
| T1-validate-contract.sh | Template contract passes the full validator incl. deadlock-config consistency | `validate-contract.sh` |

## Usage

```bash
for t in engine/scripts/eval-tasks/T*.sh; do bash "$t"; done
```

Exit 0 = pass, non-zero = fail. Tasks are read-only over the working tree
and safe to run from CI or the maintenance scheduler.
