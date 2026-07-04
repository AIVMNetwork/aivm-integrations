# Releasing brain-memory

Every plugin release ships an EXACT pinned `@aivm/brain` version (.mcp.json) — the plugin is
the update channel; the pin makes plugin↔CLI pairs atomic and testable (no npx cache drift).

Checklist:
1. Bump the pin in `.mcp.json` to the published `@aivm/brain` version.
2. Bump `version` in `.claude-plugin/plugin.json` AND `.claude-plugin/marketplace.json` (keep in sync).
3. GATE: run the agent-matrix claude-code row in aivm-brain-poc against the exact pin —
   `AIVM_BRAIN_SPEC=@aivm/brain@<pin> bash qa/agent-matrix/run.sh claude-code` — must be green.
4. `bash tests/statusline-test.sh` green.
5. Merge to main. Users pick it up via `claude plugin update brain-memory`.
