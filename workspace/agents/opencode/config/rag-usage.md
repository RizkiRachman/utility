<!-- omit from toc -->
# rag usage for agents

The workspace is indexed by the rag MCP server. Tools: `rag_search`, `rag_index`, `rag_status`, `rag_get`.

- Before implementing or answering from workspace code and docs, run `rag_search` with focused queries. Cite hits as `path:startline` in answers.
- After adding or changing many files, call `rag_index` once. The index is incremental and hash based, so unchanged files are not re-chunked.
- Spring Boot sources under `src/main/java` are chunked per method; chunk headings carry `package > class > method` context. Build outputs (`target/`, `build/`) and lockfiles are excluded from the index.
- Engine skill docs (`java-developer`, `spring-boot-enterprise`, `jpa-hibernate-patterns`, and the rest of `engine/skills/`) are in scope. Search them for project conventions before writing code.
