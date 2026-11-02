---
name: pgvector-search
description: pgvector semantic search, embeddings storage, similarity queries
triggers:
  - "pgvector"
  - "semantic search"
  - "vector embeddings"
sources:
  - url: https://github.com/timescale/pg-aiguide/blob/main/skills/pgvector-semantic-search/SKILL.md
    author: timescale
---

# pgvector Semantic Search

pgvector extension for semantic search, embeddings storage, similarity queries (cosine, L2, inner product), and hybrid search patterns.

## Source

References: **timescale/pg-aiguide** by TimescaleDB  
URL: https://github.com/timescale/pg-aiguide/blob/main/skills/pgvector-semantic-search/SKILL.md

## When to use

- Implementing semantic search with PostgreSQL
- Storing and querying vector embeddings
- Building hybrid search (BM25 + vector)

## Key topics

- pgvector extension setup and indexing
- Vector similarity functions
- IVFFlat and HNSW indexes
- Hybrid search with ranking fusion

## Load canonical skill

```
/skill pgvector-search
```