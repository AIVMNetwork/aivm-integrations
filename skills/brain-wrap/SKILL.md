---
name: brain-wrap
description: The session wrap ritual for the governed AIVM brain. Use BEFORE a session ends — when the user says "wrap up", "we're done", "/exit", "that's it for today", or when a meaningful chunk of work has just completed. Consolidates the session into durable memory so the next session (yours or a teammate's) starts already knowing what happened. Do NOT use mid-task or for a session where nothing durable occurred.
---

# Wrapping a session

The SessionEnd hook auto-syncs salient turns, but a great wrap is a deliberate act: you
consolidate the session into a clean, durable summary so recall is precise, not a pile of
raw turns. Sessions are disposable; the memory isn't.

## Workflow

1. **Review the session.** Identify what actually happened that outlives it: decisions,
   lessons, fixes, new facts, and any open threads left for next time.
2. **Consolidate, don't dump.** Capture ONE session-summary via `brain_capture`:
   - What changed (decisions + outcomes), each with its why.
   - Lessons learned and their root cause.
   - Open threads / next steps, so the next session resumes instantly.
   Reference the individual captures made during the session rather than repeating them.
3. **Update the knowledge, not just the log.** For any concept that is now different,
   capture the correction/update against the existing memory (search first — extend, don't
   duplicate). A superseded fact should be updated, not left to contradict the new one.
4. **Pin what matters.** Mark the session summary and any load-bearing decisions as pinned
   so they surface first in future recall.
5. **Verify + report.** Confirm captures returned ok, then end with a short fixed-format
   report: `Wrapped: N decisions, M lessons, K open threads captured to the brain.` If
   nothing durable happened, say exactly that — do not manufacture a summary.

## Rules

- Absolute dates, cite sources, lead with the outcome (same standard as brain-document).
- Never fabricate progress to have something to wrap. An honest "nothing durable this
  session" is correct and useful.
- The wrap consolidates what the session already captured; it is not a substitute for
  capturing at the moment (brain-document). If you skipped in-flight capture, do it now
  before consolidating.
