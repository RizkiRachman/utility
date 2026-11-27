# Efficiency & learning: measurement scope and limits

The engine ships instrumentation and gates for the efficiency and learning
stages. It does **not** claim measured production efficiency: the repository
has no production task-outcome dataset, and several signals require a runtime
provider hook that is outside this codebase. This note records exactly what is
enforced locally and what remains external, so a reader does not mistake a
checkable proxy for a proven outcome.

## What is enforced locally

| Concern | Enforcement | Evidence |
|---|---|---|
| Phases instrumented per task | `phase-telemetry.sh coverage` checks start/stop pairs by task class and task id; exits nonzero when a required phase is missing | T17 |
| Cycle time, tokens, verdict by phase/class | `phase-telemetry.sh report` aggregates completed runs only; malformed rows and orphaned starts are excluded | T7 |
| Learning record validity | `learning-record.sh` requires evidence, verifier, and expiry; stable keys update in place | T8 |
| Learning reuse | `learning-record.sh hit` / `impact` count reuse of a record across tasks | T18 |
| Judge aggregation behavior | `T9` checks verdict math and jitter on labelled fixtures | T9 |
| Completion evidence | `pre_completion` requires the ledger, bootstrap receipt, judge coverage, per-phase entries, and an active learning record | T15 |

## Explicit limits

1. **Token counts are caller-supplied.** `phase-telemetry.sh stop --tokens-in/--tokens-out`
   accepts numbers passed by the caller. The engine has no provider-usage
   hook, so it cannot observe provider billing data itself. Auto-collection
   requires an OpenCode/provider instrumentation hook that writes usage into
   the telemetry event; until that exists, token totals are a reported figure,
   not an independently measured one.
2. **Telemetry calls are instruction-driven.** The agent is instructed to emit
   `start`/`stop`; `coverage` can detect a missing phase after the fact, but
   nothing in the runtime emits the events automatically. Coverage proves a
   phase was recorded, not that the instrumentation fired at the true boundary.
3. **Judge agreement is aggregation-level.** `T9` runs deterministic verdict
   math over fixture labels and jitters a numeric score. It does not measure
   agreement between two real model judges on independently labelled real
   tasks. That needs a production-labelled dataset; the repository cannot
   supply it.
4. **Cycle time, retries, and cost per accepted change are not reported.**
   `report` gives elapsed time and token totals by phase/class, but no dataset
   in the repository links a run to an accepted change, so lighter task
   classes are not proven to be cheaper or faster. `coverage` + `report` are
   the instrumentation prerequisite; the outcome study is external.
5. **Learning impact is reuse, not recurrence reduction.** `hit`/`impact`
   show that a lesson was recalled across tasks. They cannot show that a past
   failure stopped recurring; that requires cross-session outcome tracking
   against production tasks.
6. **Shard recovery is journal-based, not a distributed transaction.** An
   `EXIT`/`INT`/`TERM` trap rolls back applied files; after `SIGKILL`, a later
   `--recover` restores from the persistent journal. This covers process
   interruption, not machine loss after the journal is removed on clean
   completion.

7. **Provenance validation is record-level.** `context-provenance.sh validate
   --source` confirms a verified record exists for a path; it does not verify
   that the file content or revision still matches what was reviewed, and
   capture is agent-invoked rather than attached to every retrieval.

8. **Schema validation is a required runtime dependency.** The controller and
   contract validator run full Draft 2020-12 validation and fail closed if
   `python3-jsonschema` is unavailable. The opencode image installs it through
   the apt package manifest; CI installs the Python package before validation.
9. **Permission scoring is not mutation forensics.** `auto-score.sh` no longer
   treats a denied policy action as a completed breach; it uses the explicit
   `governance.permissions_violated` signal. The engine does not yet compare
   protected data against a trusted execution baseline, so a mutation that
   bypasses all controller gates and omits that signal is not detected by this
   score.

These limits are deliberate: the engine enforces what it can observe and
labels what it cannot, rather than presenting a proxy as a measured result.
