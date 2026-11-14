<!-- omit from toc -->
# Opencode Workflow

Two views of the stack: how the offline package store becomes a running container, and how a task moves through the gated orchestration state machine. Gitea renders both Mermaid blocks inline.

## Build to runtime

The offline store is the lockfile: populate-preinstall resolves the latest versions at populate time, fetches them, prunes older copies, and records the result in `versions.lock`. Re-running populate is the update-everything action; between populate runs, builds stay frozen at whichever snapshot the store holds.

```mermaid
flowchart TB
    subgraph POP["populate-preinstall.sh"]
        direction TB
        P1["cert probe<br/>certs/detect-zscaler.sh"] --> P2["CA trust<br/>certs/ + update-ca-certificates"]
        P2 --> P3["resolve latest<br/>npm / PyPI / GitHub API"]
        P3 --> P4["fetch + prune<br/>version-aware guards"]
        P4 --> P5["write versions.lock<br/>audit manifest"]
    end

    subgraph STORE["pre-installer store (gitignored, portable)"]
        direction LR
        S1["npm"]
        S2["pip"]
        S3["bin"]
        S4["apt"]
        S5["git"]
        S6["dist"]
    end

    subgraph BUILD["docker build"]
        direction TB
        B1["store-first install<br/>single-match globs"] --> B2["network fallback<br/>@latest when ARG empty"]
        B2 --> B3["arch from TARGETARCH<br/>OPENCODE_ARCH optional override"]
    end

    subgraph RUN["runtime container"]
        direction TB
        R1["opencode engine<br/>17 agents / 45 skills"]
        R1 --> R2["lean-ctx"]
        R1 --> R3["context7"]
        R1 --> R4["cocoindex-code / ccc<br/>AST semantic search"]
        R1 --> R5["rag"]
        R1 --> R6["firecrawl plugin"]
        R1 --> R7["openui bridge"]
    end

    P5 --> S1
    STORE --> B1
    B3 --> R1
```

## Orchestration workflow

Every transition carries a score: rule checks first, then an LLM judge, then a combined verdict. 70 or above passes, 50 to 69 retries with feedback, below 50 (or three exhausted retries) blocks.

```mermaid
stateDiagram-v2
    direction LR
    [*] --> INIT
    INIT --> PLAN
    PLAN --> PLAN_SCORED
    PLAN_SCORED --> EXECUTE : score >= 70
    EXECUTE --> EXECUTE_SCORED
    EXECUTE_SCORED --> REVIEW : score >= 70
    REVIEW --> REVIEW_SCORED
    REVIEW_SCORED --> COMPLETE : score >= 70
    COMPLETE --> [*]

    PLAN_SCORED --> BLOCKED : score < 50
    EXECUTE_SCORED --> BLOCKED : score < 50
    REVIEW_SCORED --> BLOCKED : score < 50
    PLAN_SCORED --> EXECUTE : retry 50-69 (max 3)
    EXECUTE_SCORED --> EXECUTE : retry 50-69 (max 3)
    REVIEW_SCORED --> REVIEW : retry 50-69 (max 3)
    BLOCKED --> EXECUTE : user guidance

    note right of PLAN_SCORED
        Scoring tiers per transition:
        1. rule-based checks (deductions)
        2. LLM-as-judge (0-100)
        3. combined verdict: >= 70 PASS
    end note
```