# confidential-smart-contract

A Starknet contract whose **state lives off-chain** (published nowhere) and is
**anchored on-chain by a single Poseidon commitment**, with the **compute run
off-chain via SNIP-36** virtual block proving. On-chain, Starknet only verifies a
proof and compare-and-swaps the anchor. Validium-style, but confidential.

**Status:** v1 (monolithic counter) ✅ **verified end-to-end on Sepolia (2026-07-02)**. **v2**
is a generic framework — a frozen dispatcher + **confidential pluggable logic** (the governing
logic's class hash lives inside the committed state). **v3** adds **public interaction**: a
transition can **read public state** and trigger **public calls** (e.g. move ERC-20s) through a
pull-based **outbox** (`apply_transition` records → permissionless `consume` executes). **v4**
adds the **inbox** — the public → shard dual: trustlessly-attributed `deposit`s and
`register_intent`s that the confidential logic observes via proven reads — plus `outbox_of`
settlement observability, a per-shard freshness gate (default off), and an indexable DA
channel; the reference outbox app is **`CommitteeLogic`** (a confidential M-of-N committee
whose threshold-approved decisions emit arbitrary public calls, approvals verified in-proof).
It **compiles** (Scarb/Cairo 2.18), has a **generic orchestration SDK** and **25 passing
snforge tests**. Both the v2 and the **v3+v4 deep audits were clean** (0 Critical/High; the
v3+v4 pass surfaced 3 below-threshold notes, all now fixed or documented); a fresh Sepolia
deploy is pending (see [status](docs/project/STATUS.md)).

---

## Where to find things

| I want to… | Go to |
|------------|-------|
| Understand **why** the system is designed this way | [`DESIGN.md`](./DESIGN.md) — architecture source of truth |
| Get a **map of the code** | [`docs/code/overview.md`](docs/code/overview.md) |
| Read the **Cairo contract** internals | [`docs/code/cairo.md`](docs/code/cairo.md) |
| Understand the **off-chain client / proving flow** | [`docs/code/orchestration.md`](docs/code/orchestration.md) |
| See **what's done / what's next** | [`docs/project/STATUS.md`](docs/project/STATUS.md) |
| Read the **development history** | [`docs/project/LOG.md`](docs/project/LOG.md) |
| Learn **how to work on / hand off this project** | [`docs/project/PROCESS.md`](docs/project/PROCESS.md) |

**Two-doc rule of thumb:** `DESIGN.md` explains the *idea*; `docs/code/` explains
the *code as written*. If they ever disagree, the code + `docs/code/` win for
"what is," `DESIGN.md` wins for "what was intended."

---

## Repository layout

```
confidential-smart-contract/
├── README.md                 # ← you are here: the navigation hub
├── DESIGN.md                 # architecture (source of truth)
├── Scarb.toml                # Cairo package
├── src/                      # Cairo: framework (ConfidentialShard) + pluggable logics + outbox + types
├── orchestration/            # off-chain client (TypeScript / Node, strkd flow)
└── docs/
    ├── code/                 # documentation of the code
    │   ├── overview.md
    │   ├── cairo.md
    │   └── orchestration.md
    └── project/              # project-management documentation
        ├── STATUS.md         # current state (whiteboard)
        ├── LOG.md            # history (diary, append-only)
        └── PROCESS.md        # how we track & hand off work
```

---

## Project management

Development is tracked in [`docs/project/`](docs/project/), governed by
[`docs/project/PROCESS.md`](docs/project/PROCESS.md):

- **[`STATUS.md`](docs/project/STATUS.md)** — the current snapshot (done / in
  progress / next / risks). Start here to see where things stand.
- **[`LOG.md`](docs/project/LOG.md)** — append-only history of each work session.
- **[`PROCESS.md`](docs/project/PROCESS.md)** — the prescriptive workflow: how to
  claim work, log progress, update status, and pick up cold.

> **If you do any work on this project, you must follow `PROCESS.md`** — at minimum,
> log the session in `LOG.md` and update `STATUS.md`. A change that isn't recorded
> there effectively didn't happen, as far as the next person can tell.

---

## Contributing to the documentation

Keep the docs navigable by following these rules. **Docs change in the same commit
as the code they describe — never "later."**

**Where things go**
- Documentation of *code* → `docs/code/`. Documentation of *how we run the project*
  → `docs/project/`. Architecture rationale stays in `DESIGN.md` (don't duplicate it
  — link to it).
- **One topic per file.** A file should answer one question. If a doc grows two
  distinct topics, split it and link between them.

**Naming & format**
- Lowercase `kebab-case.md` in `docs/` (the `docs/project/` status files are
  intentionally `UPPERCASE.md` because they're canonical touchpoints — keep that).
- Start every doc with a one-line blockquote saying what it is and pointing to its
  neighbours.

**Navigability (the important part)**
- **No orphans.** Every doc must be reachable from the *Where to find things* table
  above. When you add, move, or remove a doc, update that table **and** the
  Repository layout tree in the same change.
- **Cross-link with relative paths** (`./`, `../`) so links work on GitHub and in
  editors. Prefer linking to a section over restating it.
- **No duplication.** State a fact in exactly one doc and link to it. Duplicated
  facts drift out of sync; a link never does.
- Keep docs **describing what is true now.** History belongs in
  [`LOG.md`](docs/project/LOG.md), not scattered through code docs.

**When code changes:** update the matching `docs/code/` doc, verify its links still
resolve, and confirm the *Where to find things* table + layout tree are still
accurate.

---

## Quick start

```bash
scarb build                          # compile the Cairo contract (Scarb/Cairo 2.18)
snforge test                         # 25 tests
cd orchestration && npm install      # off-chain client deps
```

Running the full SNIP-36 flow (prove + submit) needs a `strkd` wallet companion and
a configured prover; see [`docs/code/orchestration.md`](docs/code/orchestration.md).
