# Releasing brain-memory

Every plugin release ships an EXACT pinned `@aivm/brain` version (.mcp.json) — the plugin is
the update channel; the pin makes plugin↔CLI pairs atomic and testable (no npx cache drift).

Checklist:
1. Bump the pin in `.mcp.json` to the published `@aivm/brain` version.
2. Bump `version` in `.claude-plugin/plugin.json` AND `.claude-plugin/marketplace.json` (keep in sync).
3. GATE: run the agent-matrix claude-code row in aivm-brain-poc against the exact pin —
   `AIVM_BRAIN_SPEC=@aivm/brain@<pin> bash qa/agent-matrix/run.sh claude-code` — must be green.
4. `bash tests/statusline-test.sh` green.
4a. `bash tests/statusline-auth-state-test.sh` green — the M1 gate. The statusline renders WHO YOU
    ARE SIGNED IN AS; this suite is what proves a revoked key stops claiming the last-known-good
    identity, and that a 404 or a 503 is never rendered as a revocation.
4b. **GATE (cross-repo): `AIVM_BRAIN_PKG=<path>/packages/aivm-brain bash tests/embed-drift-check.sh`
    green.** `statusline/*.sh` in THIS repo is the CANONICAL source; the CLI ships a GENERATED copy
    at `packages/aivm-brain/src/statusline-scripts.ts`, produced by `scripts/embed-statusline.cjs`,
    which reads these files and overwrites that one wholesale. Releasing is the only moment both
    trees are present, so it is the only place they can be proven identical — this repo's own CI
    skips this check explicitly, by necessity. If it fails, READ THE DIFF BEFORE REGENERATING: on
    2026-08-13 the generated copy held a `resets_at` feature that existed nowhere else (canonical 0
    occurrences, generated 5), and regenerating first would have deleted it while looking clean.
5. Merge to main. Users pick it up via `claude plugin update brain-memory`.

Notes (from plan audit 2026-07-04):
- Propagation is PULL-based: users must run `claude plugin marketplace update aivm` then
  `claude plugin update brain-memory@aivm`, then restart. Merging to main IS the release,
  but nobody gets it until they pull (founder's own clone sat at v0.1.1 while main was 0.2.0).
- Content gate: every brain_* tool named in skills/ and commands/ MUST exist in the pinned CLI
  (0.2.8 shipped brain-push.md referencing brain_upload_batch, which 0.2.8 lacks — never again).
- Versioning: plugin versions are INDEPENDENT of CLI versions (0.3.0 plugin pins 0.3.1 CLI);
  the pair is recorded here per release, not by matching numbers.
