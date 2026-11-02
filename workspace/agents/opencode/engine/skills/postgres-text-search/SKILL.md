---
name: postgres-text-search
description: Full-text search, hybrid search, tsvector, GIN indexes
triggers:
  - "full-text search"
  - "tsvector"
  - "GIN index"
sources:
  - url: https://github.com/timescale/pg-aiguide/blob/main/skills/postgres-hybrid-text-search/SKILL.md
    author: timescale
---

# PostgreSQL Full-Text Search

PostgreSQL full-text search with tsvector/tsquery, GIN indexes, hybrid search combining text and vector, and ranking strategies.

## Source

References: **timescale/pg-aiguide** by TimescaleDB  
URL: https://github.com/timescale/pg-aiguide/blob/main/skills/postgres-hybrid-text-search/SKILL.md

## When to use

- Implementing full-text search in PostgreSQL
- Combining text and semantic search
- Optimizing search performance

## Key topics

- tsvector and tsquery construction
- GIN index optimization
- Ranking with ts_rank and ts_rank_cd
- Hybrid search with pgvector

## Load canonical skill

```
/skill postgres-text-search
```