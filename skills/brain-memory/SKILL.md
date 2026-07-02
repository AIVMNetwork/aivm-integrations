---
name: brain-memory
description: Recall discipline for the governed AIVM brain. Use at the START of any task that touches company knowledge — prior decisions, architecture, people, processes, customers, past incidents — and whenever the user asks "what do we know / what did we decide / how do we usually" questions. Also use when a [aivm-brain] recall block appears in context. Do NOT use for pure code mechanics in the open files, or for general world knowledge the brain wouldn't hold.
---

# Using your governed brain

Your brain (Brain by AIVM) is the team's shared, permission-aware memory. Every search and
capture is access-checked against YOUR clearance and recorded to a tamper-evident ledger.
You only ever see what this identity is cleared to see.

## Workflow

1. **Recall before you reason.** Before answering anything about the company, its work, or
   its history, call the aivm-brain `brain_search` tool with a focused natural-language
   question. One broad search beats three narrow ones — each extra call costs latency.
2. **Trust the injected recall.** When a `[aivm-brain]` block is already in your context
   (the plugin injects one per prompt), treat it as governed context: use it, cite it, and
   do not re-search for the same fact.
3. **Cite what you use.** Facts from the brain are attributed — reference the source
   document title (or ledger id when shown). Never present brain knowledge as your own
   general knowledge.
4. **Respect withholding.** "N source(s) withheld" means relevant knowledge exists that
   this identity is NOT cleared for. Say so plainly ("there is additional material I'm not
   cleared to see") — never guess at withheld content, never ask the user to bypass it.
5. **Say UNKNOWN honestly.** If the brain returns nothing and you have no other grounded
   source, say the brain doesn't hold this yet — and capture the answer once it's
   established (see the brain-document skill). Never invent a plausible answer.
6. **Verify freshness when it matters.** Brain facts are point-in-time. For anything
   load-bearing (a deploy target, an owner, a price), check the cited document's date and
   flag staleness instead of asserting it as current.

## Failure modes (if you catch yourself doing one of these, it is a misread of this skill)

- Answering a "what did we decide" question from memory of THIS conversation instead of
  searching the brain — the decision may have been superseded by someone else's session.
- Concluding "not found" and silently moving on — the gap itself is worth telling the user
  and worth capturing once resolved.
- Re-running the same search with rephrasings to "retry" an empty result. One reformulation
  is fine; more is noise.
