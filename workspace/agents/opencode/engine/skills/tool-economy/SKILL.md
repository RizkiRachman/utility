# Tool Call Economy

Mandatory tool-call discipline for all agents. Every tool call is one full LLM inference round-trip; wasted calls are wasted inference, latency, and quota. Use when planning any multi-step task, delegating to subagents, or when a task exceeds its turn budget.

## The Six Rules

1. **Batch rule**  -  2+ independent tool calls: one turn, parallel. Serialized independent calls are the most common waste pattern.
2. **Chain rule**  -  dependent commands on the same tool: one call chained with `&&` (commit-push-sync-verify is ONE call, not five).
3. **Gate-first rule**  -  check policy/security constraints BEFORE composing a command. A blocked command costs a full wasted inference. Never retry-blind; reroute through the sanctioned path (native edit, scratch-file + mv, file-mode interpreters).
4. **Spawn-tax rule**  -  subagent prompts carry complete context: requirements, decisions, retry issues, exact file paths, validation steps. A subagent that re-discovers state burns turns the parent already paid for.
5. **Tier rule**  -  execution tiers by blast radius x reversibility x ambiguity:

   | Tier | When | Flow | Budget |
   |---|---|---|---|
   | T1 Direct | 1-2 files, git-revertible, clear scope | orchestrator inline: edit -> check -> commit -> push -> verify | <=10 turns |
   | T2 Light | 3-10 files or parallelizable | max ONE subagent, full-context prompt, orchestrator verifies | <=20 turns |
   | T3 Full | security-sensitive, ambiguous, multi-service, audit requested | analyst -> developer -> review, all gates | unconstrained |

6. **Verdict rule**  -  mechanical decisions (score pass/fail, route choice, risk class, retry-or-stop): single-shot no-tools inference on the cheapest capable model. Never a tool-loop turn.

## Retrieval Routing

| Question type | Tool (1 call) | Never |
|---|---|---|
| Exact symbol, callers, blast radius | ctx_search symbol / ctx_impact | grep sweeps |
| How does our code do X | rag_search (scope with glob) | opening many files |
| Library/framework API | context7 | guessing, random web |
| Errors, issues, PR discussions | firecrawl_developer_search | broad web search |
| Single known page | fetch | scrape-first |
| Past decisions, conventions | ctx_knowledge recall | re-deriving |

## Anti-patterns (real incidents)

- Content-scan rejection on staged literals (printf/base64 routes) cost 3 wasted inferences. Gate-first: use the sanctioned write path directly.
- Subagent spawn on executor tier died on provider quota with no automatic fallback. Re-dispatch explicitly with the fallback model set (documented platform gap, engine agent.md §6).
- Parallel commands raced a fresh git clone and edited missing files. Dependent steps chain into ONE call (chain rule).

## Turn budgets

T1 <=10 turns, T2 <=20, T3 unconstrained. Exceeding budget: stop, report state, then either simplify the approach or escalate to the user.
