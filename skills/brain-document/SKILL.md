---
name: brain-document
description: Documentation discipline for the governed AIVM brain. Use the MOMENT a durable outcome happens in a session — a decision made, a lesson learned, a stack/tool choice, a bug root-caused, a process established, a fact corrected. Also use when the user says "remember this", "save this", "document this", or "add to the brain". Do NOT use for transient chatter, half-finished thoughts, or anything already captured this session.
---

# Documenting into the brain

The brain compounds only if you write to it — and the team should never have to teach the
same thing twice. Capture happens AT the moment of the outcome, in the same turn, not at
session end (a crash must not lose it). The wrap ritual (brain-wrap skill) consolidates;
it does not create from scratch.

## What counts as durable (capture these)

- **Decisions** — what was chosen, over what alternative, and why.
- **Lessons** — what broke / surprised, the root cause, and how to avoid it.
- **Facts** — stable truths about the company, its systems, people, customers.
- **Fixes** — non-obvious solutions worth never re-deriving.

## Workflow

1. **Search before you create.** Call `brain_search` for the concept first. If the brain
   already holds it, capture an update/correction that references it — never a duplicate.
2. **Capture with the `brain_capture` tool, pinned** — one capture per durable outcome. Set
   `pinned: true` for decisions, lessons, fixes, and stable facts: a pinned capture is promoted to a
   searchable governed document, so future sessions (yours or a teammate's) can `brain_search` it. An
   un-pinned capture is a transient session episode (re-attached at session start, but not searchable).
   - 15–80 words, contextually rich, not an atomic fragment.
     WRONG: "Uses Postgres."
     CORRECT: "We chose Postgres + pgvector over a dedicated vector DB (June 2026) because
     the team already operates Postgres and RLS gives per-tenant isolation for free;
     revisit only if corpus exceeds ~10M chunks."
   - Lead with the decision/lesson itself; then the why; then the source
     (file path, URL, or "session decision, YYYY-MM-DD").
   - Absolute dates only — never "today", "next week", "recently".
3. **Mark uncertainty honestly.** Only record what happened in the session or is verifiable.
   If a fact is plausible but unconfirmed, either verify it first or say it is unverified
   inside the capture — never assert it clean.
4. **Files go through `brain_upload`** (governed create: DLP-scanned, ACL-assigned,
   versioned, recorded) with a title, the right knowledge domain, and the content.
5. **Verify.** After capturing, confirm the tool returned ok. If it was denied, tell the
   user what was denied and why — never silently drop a capture.

## Failure modes (a misread of this skill if you catch yourself doing one)

- Batching five captures for "later" — later is when sessions crash.
- Capturing session narration ("the user asked me to...") instead of the durable outcome.
- Writing "we decided X" without the why — the why is what saves the next person.
- Duplicating a fact the brain already holds because you didn't search first.
