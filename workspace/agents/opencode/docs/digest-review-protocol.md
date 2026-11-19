# Digest Review Protocol - external reviewer pre-gate

External reviewers audit the agent-consumption digest each round. This protocol
defines the provenance evidence every review must carry and the rejection rules
applied before triage. Two failure modes from past rounds motivate it: partial
scans reported as full audits, and a review describing files that do not exist
in the repository.

## 1. Provenance block (mandatory, before any verdict)

A review enters triage only if it opens with three items:

- **Corpus identity.** The manifest-declared byte size and file count of the
  corpus as served, quoted verbatim.
- **Line anchors.** The requester supplies three file and line pairs drawn from
  the pack; the reviewer quotes each line within a two-line tolerance, verbatim.
  A reviewer who cannot quote them has not read the corpus. This
  challenge-response is what catches a hallucinated review.
- **Fetch budget.** One line stating the fetch cap encountered and the share of
  the corpus actually scanned.

## 2. Coverage accounting

- **FULL**: the entire corpus scanned in one pass.
- **PARTIAL**: the scan stopped before the end. The review must state the exact
  file and section where it stopped, and its findings count only inside that
  region.
- **UNVERIFIED**: no coverage claim accepted. Findings are treated as rumors,
  not defects.

## 3. Sanity gate (run before the verdict)

A tripped gate marks the pack stale, not the review wrong:

- graphify appears exactly 3 times, all inside engine/scripts/check-cross-references.sh -
  the docstring, the sweep pattern, the log line. Any occurrence outside the
  checker and this document fails the gate, because this document defines the
  gate.
- docs/git-mirrors.md must be present. The control probe is a deliberately
  wrong filename: it must return the not-found signature, never real content.
- Numeric count claims for agents and skills are enforced mechanically by
  check 10 of engine/scripts/check-cross-references.sh against live filesystem
  counts. Reviewers re-report what the check reports; they do not re-derive
  counts from a truncated fetch.

## 4. Rejection rules

- Missing provenance block: review rejected without triage.
- Describes files, scripts, or structures absent from the manifest:
  hallucination flag, review discarded, noted in the audit ledger. Example from
  round 7: a kb-curator agent, a state/state.json store, a SCORING.md with 0.85
  thresholds, model tiers naming claude-opus and gpt-5.3 - none exist in this
  repository.
- Verdict without a coverage label: treated as PARTIAL with unknown coverage.
- A corpus dump submitted as a review: not a review. Re-dispatch.

## 5. Known-legal notes

- The pack is minified. A count that lives only in a stripped comment can vanish
  from the pack; verify against the raw file endpoint before flagging drift.
- The engine keeps 17 agents and 46 skills. If check 10 reports a mismatch, the
  docs are wrong until proven otherwise, because the check compares against the
  live tree.
