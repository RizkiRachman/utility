# tools

Helper scripts and small binaries used by the stack and by agents. The directory is empty today.

## What belongs here

Single-file utilities that serve more than one module and have no better home: repository maintenance scripts, one-off migration helpers, small inspectors. Anything that belongs to one submodule's build or runtime belongs in that submodule instead.

## Conventions

- Each tool carries a header comment: what it does, what it needs, an example invocation.
- Stay dependency-free where practical (shell, python stdlib, node core). If a tool needs a real dependency, it probably belongs in a submodule with a proper package manifest.
- Executable bit set, no compiled artifacts committed.
