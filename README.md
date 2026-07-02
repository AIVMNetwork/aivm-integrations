# Brain by AIVM — Claude Code plugin

Governed, verifiable memory for your AI agents. Install it once and every session
automatically recalls what your company knows and syncs what you learn back — with a
tamper-evident record of every access, scoped to what your identity is cleared to see.

## Install

```
claude plugin marketplace add AIVMNetwork/aivm-integrations
claude plugin install brain-memory@aivm
```

Then set your credentials (get them from **brain.aivm.io → Connect Claude Code**):

```
export AIVM_BRAIN_URL="https://brain.aivm.io"
export AIVM_AGENT_KEY="ak_..."     # your one-time agent key
```

Restart Claude Code (plugins + MCP load at startup). That's it.

## What it does — automatically

| Lifecycle | Hook | Effect |
|---|---|---|
| Session start | `SessionStart` | Loads your governed company context into the session. |
| Each prompt | `UserPromptSubmit` | Injects ACL-filtered recall relevant to what you're asking. |
| Before compaction | `PreCompact` | Emits a memory anchor so context survives compaction. |
| Session end | `SessionEnd` | Syncs the salient turns into governed memory (in the background). |

Every capture is attributed to your agent identity and hash-chained in the ledger.

## Skills

- **brain-memory** — recall discipline: search before answering, cite sources, respect withholding.
- **brain-document** — capture decisions/lessons/fixes the moment they happen.
- **brain-wrap** — consolidate a session into durable memory before you exit.

## Commands

The brain-wrap **skill** auto-fires near session exit — no command needed. Manual utilities:

- `/brain-status` — what's in your brain + sync state.
- `/brain-push [folder]` — upload local notes/files into the governed brain (searchable immediately).

## Why it's different

Unlike ungoverned memory plugins, every read and write is **permission-aware** (you only
see what you're cleared to), **content-blind auditable** (a tamper-evident ledger of every
access, never your content), and **agent-attributed** (each capture carries your agent's
identity). Bring your own model key — nothing you connect trains a model.

MIT licensed. The memory backend runs at your brain (`AIVM_BRAIN_URL`); the plugin is thin
wiring over the published `@aivm/brain` MCP server.
