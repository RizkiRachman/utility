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

## Usage

```bash
for t in engine/scripts/eval-tasks/T*.sh; do bash "$t"; done
```

Exit 0 = pass, non-zero = fail. Tasks are read-only over the working tree
and safe to run from CI or the maintenance scheduler.
