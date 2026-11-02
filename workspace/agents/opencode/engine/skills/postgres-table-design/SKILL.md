---
name: postgres-table-design
description: PostgreSQL schema design, indexing strategies, partitioning, constraints
triggers:
  - "PostgreSQL schema"
  - "table design"
  - "indexing strategy"
sources:
  - url: https://github.com/timescale/pg-aiguide/blob/main/skills/design-postgres-tables/SKILL.md
    author: timescale
---

# PostgreSQL Table Design

PostgreSQL schema design patterns, indexing strategies, partitioning approaches, and constraint management for performant databases.

## Source

References: **timescale/pg-aiguide** by TimescaleDB  
URL: https://github.com/timescale/pg-aiguide/blob/main/skills/design-postgres-tables/SKILL.md

## When to use

- Designing new PostgreSQL schemas
- Optimizing table performance
- Implementing partitioning

## Key topics

- Schema normalization vs denormalization
- B-tree, Hash, GiST, GIN indexes
- Table partitioning (range, list, hash)
- Check constraints and foreign keys

## Load canonical skill

```
/skill postgres-table-design
```