<!-- omit from toc -->

# Orchestration Contract & Workflow

> **Contract template**: `contract/contract.template.json`
> **State machine rules**: `rules/rules.json`

The orchestration contract is the shared JSON envelope that tracks every task from start to finish. This directory splits the full workflow reference into 5 focused documents.

**Read first: [01-fundamentals.md](./01-fundamentals.md)** — State machine, contract envelope, and the mandatory read→activity→write protocol.

## Quick Reference: Contract Read/Write Protocol

| Phase | Reads from Contract | Activity | Writes to Contract | Delegated To |
|---|---|---|---|---|
| INIT→PLAN | requirements.*, governance.*, retry.issues[] | Refine requirements + system design & plan | state: PLAN, session.*, scope.* | product-manager → system-analyst |
| PLAN→PLAN_SCORED | outputs.plan, scope.* | Score plan (+ SDD spec) | state: PLAN_SCORED, score.*, decisions.* | orchestrator (+ software-architect) |
| EXECUTE→EXECUTE_SCORED | outputs.code_changes[], outputs.test_results | Score implementation | state: EXECUTE_SCORED, score.* | orchestrator |
| EXECUTE_SCORED→REVIEW | score.*, outputs.* | Code quality + security review | state: REVIEW | quality-analyst + security-engineer |
| REVIEW→REVIEW_SCORED | outputs.agent_reports[] | Score review findings | state: REVIEW_SCORED, score.*, outputs.score_summary | orchestrator |
| REVIEW_SCORED→COMPLETE | score.*, outputs.* | Ship, learn, persist (scrum-master DoD gate) | state: COMPLETE, lessons_learned[], metrics.* | learner |
| At BLOCKED | retry.issues[], retry.cur_phase | Escalate, arbitrate, persist | state: BLOCKED, retry.escalation_trace[], retry.attempt+1 | scrum-master |


## File Index

| File | Content | When to Read |
|------|---------|-------------|
| [01-fundamentals.md](./01-fundamentals.md) | State machine, contract envelope, R/W protocol | Every session start |
| [02-lifecycle.md](./02-lifecycle.md) | Phase walkthrough, gates, BLOCKED | During planning/execution |
| [03-agents.md](./03-agents.md) | 15-agent integration matrix, tools, skills | Before delegation |
| [04-scoring.md](./04-scoring.md) | 3-tier scoring, validation gates, governance | During scoring/review |
| [05-operations.md](./05-operations.md) | Post-flight, session lifecycle, scripts | Before commit/save |

[workflow-shield]: https://img.shields.io/badge/Workflow-Orchestration-blue?style=for-the-badge
