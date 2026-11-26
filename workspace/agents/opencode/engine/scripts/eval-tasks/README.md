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
| T4-score-calibration.sh | Verdict boundaries, tier1_only cap, permissions halt | `auto-score.sh` thresholds + an 11-case corpus |
| T5-controller-integration.sh | Controller policy, scope, evidence, completion, concurrency | `workflow-controller.sh` + `transition.sh` |
| T6-judge-coverage.sh | Malformed ledger rows never count as judge evidence | `judge-coverage.sh` |
| T7-telemetry.sh | Per-phase timing/token aggregation excludes orphaned runs | `phase-telemetry.sh` |
| T8-context-provenance.sh | Context records carry source, commit, timestamp, evidence status | `context-provenance.sh` |
| T9-judge-agreement.sh | Labeled verdict corpus: agreement, false-pass/block, jitter flips | `fixtures/judge-labels.jsonl` |
| T10-blocked-sla.sh | BLOCKED TTL stamped on transition and enforced against rules | `blocked-sla.sh` + `transition.sh` |

## Usage

```bash
for t in engine/scripts/eval-tasks/T*.sh; do bash "$t"; done
```

Exit 0 = pass, non-zero = fail. Tasks are read-only over the working tree
and safe to run from CI or the maintenance scheduler.
