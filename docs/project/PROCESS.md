# Project-Management Process

> **How development of this project is tracked and handed off.** Prescriptive by
> design — follow it so anyone (human or agent) can pick up cold. If you change the
> process, update this file.

## The three project docs

| Doc | Answers | Shape |
|-----|---------|-------|
| [`STATUS.md`](./STATUS.md) | *Where are we right now?* | Current-state snapshot: Done / In progress / Next / Risks. Overwritten as state changes. |
| [`LOG.md`](./LOG.md) | *What happened, and why?* | Append-only, reverse-chronological session entries. Never rewrite history. |
| [`PROCESS.md`](./PROCESS.md) | *How do we work?* | This file. The rules. |

**Rule of thumb:** `STATUS.md` is a whiteboard (always current, no history);
`LOG.md` is a diary (history, never edited after the fact).

## Every work session

Do these, in order:

1. **Orient** (see *Picking up work* below).
2. **Claim the work.** Move the item you're starting from *Next* to *In progress*
   in `STATUS.md`. If it's not listed, add it.
3. **Do the work.**
4. **Log it.** Prepend a dated entry to `LOG.md` using the template at the top of
   that file. One entry per session. Be honest about blockers and dead ends —
   they're the most valuable part for the next person.
5. **Update `STATUS.md`.** Move completed items to *Done*, adjust *Next*, update the
   `Last updated` date and the one-line state. Add any new risks.
6. **Update code docs if the code changed** — see the docs-contribution rules in the
   root [`README.md`](../../README.md). Docs and code land together, not "later."

> If you did *no* durable work (just investigation), still log it — a "tried X, it
> doesn't work because Y" entry saves the next person hours.

## How to log progress (LOG.md)

- **When:** at the end of every session that changed the repo or learned something
  that affects the plan.
- **Format:** the template at the top of `LOG.md` (`Did / Why / Blockers / State
  after / Next`). Don't deviate — consistent structure is what makes it scannable.
- **Dates:** absolute (`YYYY-MM-DD`), newest on top.
- **Granularity:** one entry per session, not per commit. Reference commits / tx
  hashes inline.
- **Never** delete or rewrite past entries. Correct a mistake with a new entry.

## How to update STATUS.md

- Keep the four sections (Done / In progress / Next / Risks) plus the header
  (`Last updated`, `Phase`, one-line state) current.
- *In progress* should usually have **0–2 items**. If it's growing, you're
  context-switching too much.
- When you finish something, move it to *Done* the same session — a stale board is
  worse than no board.
- *Next* is ordered by priority; re-order freely as priorities shift.

## Picking up work from where you left off

Read, in this order (5 minutes, cold start):

1. **`STATUS.md`** — the current snapshot and the top *Next* item.
2. **The latest `LOG.md` entry** — its `Next:` line is your starting point and its
   `Blockers:` line warns you of traps.
3. **Session memory** — this project keeps Claude Code memory (deployed artifacts,
   gotchas, the resolved prover-version note). It's loaded automatically for agents;
   humans can skim `docs/project/` instead.
4. **The relevant code doc** (`docs/code/`) for whatever you're about to touch.

Then claim the item (step 2 above) and go. **Do not** re-derive settled decisions —
`DESIGN.md` is the architecture source of truth and its "Open decisions" are now
resolved (recorded in `LOG.md`).

## Definition of done (for a *Next* item)

An item is *Done* only when: the work is complete **and** verified (tests pass /
behavior confirmed on-chain, not just "compiles"), the code docs reflect it, and a
`LOG.md` entry records it. "Compiles but untested" stays *In progress*.

## Tooling notes

- **Claude Code `TaskCreate`/`TaskUpdate`** are for *intra-session* task tracking
  (ephemeral, per-conversation). They are **not** a substitute for `STATUS.md` /
  `LOG.md`, which are the durable, committed record. Use tasks to drive a session;
  use these docs to persist across sessions.
- **Session memory** (`~/.claude/.../memory/`) complements these docs with
  agent-facing pointers; keep the two consistent (e.g. deployed addresses appear in
  both `STATUS.md` and memory).
