# infrastructure/k6

Load-test scripts and scenarios for k6. The directory is empty today; the compose file already knows about it.

## What belongs here

- Scenario scripts (`*.js`) using k6's HTTP and WebSocket APIs.
- Threshold definitions live inside each script: the script states its own pass/fail limits.
- Shared helpers (auth setup, environment parsing) in a `lib/` subdirectory when a second script needs them.

## Rules

- Tests run against target hosts read from the environment. Never hardcode a host, and never point a test at anything outside this stack.
- Keep each scenario deterministic where practical: fixed seed data, no reliance on prior run state, so results compare across runs.
- Name scripts after what they exercise (`<service>-<scenario>.js`); the filename is the label in result output.
