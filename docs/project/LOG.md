# Progress Log

> Append-only, **reverse-chronological** (newest at top) diary of what happened and
> why. This is the narrative history; the current-state snapshot is
> [`STATUS.md`](./STATUS.md). See [`PROCESS.md`](./PROCESS.md) for when and how to
> add entries.

## Entry format

Copy this template to the top of the log (under this heading) for each work session:

```
## YYYY-MM-DD — <short title>

**Did:** <what was accomplished this session>
**Why / decisions:** <notable choices and their rationale>
**Blockers / surprises:** <anything that went sideways; how it was resolved or is it open>
**State after:** <where things stand; what STATUS.md now reflects>
**Next:** <the intended next step for whoever picks up>
```

Keep entries factual and dated. Convert relative dates to absolute. Link commits,
tx hashes, or [[memory]] items where useful.

---

## 2026-07-02 — Fix audit finding #2 (ungated reference upgrade)

**Did:** Removed the upgrade path from the reference counter — `CounterLogic` is now an
immutable dummy (`step` always returns its own class hash and ignores any extra
`public_input`). Deleted the now-redundant `ImmutableCounterLogic`. Updated the SDK counter
example (`buildPublicInput` = `[step]`, `nextState` keeps the logic hash; dropped `upgradeTo`)
and the tests.

**Why / decisions (with the user):** The user chose to make the reference counter immutable
rather than ship a gated upgradeable variant. No reference logic ships an ungated upgrade
path, so the permissive pattern can't propagate by copy-paste. The framework still SUPPORTS
upgrades (a production logic returns a different, self-gated successor from `step`) — it's
just not demonstrated by a reference.

**State after:** `scarb build` clean; **6 snforge tests pass** (logic immutability + framework
immutability-through-the-framework + salt rotation + zero-salt guard); typecheck clean.
Classes now `ConfidentialShard 0x57e64f78…` and `CounterLogic 0x4c5c6dcb…` (changed;
`ImmutableCounterLogic` removed). **Both audit findings now fixed.**

**Next:** fresh Sepolia deploy demoing salt rotation; optionally a gated upgradeable logic
example if upgrades are ever wanted.

## 2026-07-02 — Fix audit finding #1 (constant salt reuse)

**Did:** Implemented per-transition salt rotation. `transition` now takes a caller-supplied
`new_salt: felt252` and commits the successor state under it (`assert new_salt != 0`); the
current salt still binds `old_root`. So every root uses an independent, fresh, high-entropy
salt — recovering one no longer cascades across the shard's history. Salt stays a
framework-level concern; the logic never sees it. Updated the SDK (`framework.ts`:
`transitionCalldata(…, newSalt)` + `freshSalt()` CSPRNG helper; `examples/counter.ts`:
`nextState` mirror; `orchestrate.ts`: fresh salt per transition + real `new_root` pre-check).

**Why / decisions:** Chose caller-supplied fresh randomness over deterministic salt chaining
(`salt_next = poseidon(salt,…)`) — chaining still cascades from a single recovered salt,
whereas independent per-transition salts fully close the finding.

**State after:** `scarb build` clean; **7 snforge tests pass** (added
`transition_rejects_zero_new_salt` + rotation assertions); orchestration typecheck clean.
Framework class hash changed → `0x57e64f78…` (signature change; logics unchanged). Docs +
STATUS updated; finding #1 marked FIXED.

**Next:** finding #2 (gated reference logic / mark `CounterLogic` non-production); fresh
Sepolia deploy demoing upgrade + ratchet + salt rotation.

## 2026-07-02 — Generic orchestration SDK, snforge tests, fresh audit

**Did:** (1) Rewrote orchestration as a generic, logic-agnostic SDK — `framework.ts`
(commit/calldata/message encodings mirroring the Cairo), `strkd.ts` (companion client),
`rpc.ts` (read helpers), `examples/counter.ts` (the counter as one `Example`),
`orchestrate.ts` (generic driver parameterized by an Example). Removed the v1 `.mjs`
scripts; `npm run typecheck` clean. (2) Added snforge tests — **6 passing**: logic `step`
(increment, u128-overflow revert, upgrade directive, immutability ratchet) + framework
`transition` (recomputes `commit`, asserts the emitted L2->L1 message, incl. upgrade
committing the new logic hash). (3) Ran a fresh deep `cairo-auditor` on the framework + logics.

**Audit result (Execution Integrity: FULL):** 0 Critical/High. **1 Medium (conf 78)** —
constant `salt` reuse: a shard uses one salt for life, so recovering it (feasible only
under low-entropy salt) cascades to its whole history; fix = rotate salt / require high
entropy. **1 Low (conf 55)** — reference `CounterLogic`'s upgrade path is ungated
(successor from `public_input`, no in-logic authorization): fine for a single-custodian
shard (the chosen self-governance), a hijack primitive for shared state; fix = mark the
reference non-production / ship a gated variant. All other candidates (message forgery,
run-a-different-logic, storage corruption, hidden `replace_class`, ratchet bypass,
cross-shard replay, determinism) dropped as false-positive — **core design confirmed sound**.

**Blockers/surprises:** `MessageToL1.to_address` is `EthAddress` (test fix); `res.json()`
is typed `unknown` (SDK cast). `apply_transition`'s proof_facts path isn't snforge-testable
(no proof_facts cheatcode) — covered by the v1 Sepolia run + the SDK `checkProof` mirror.

**State after:** Framework compiles, 6 tests pass, audited (findings unfixed). Orchestration
generic. Not deployed.

**Next:** salt rotation (finding #1); gated reference logic / mark `CounterLogic`
non-production (finding #2); fresh Sepolia deploy demoing an upgrade + the ratchet.

## 2026-07-02 — Generic framework refactor (v2: ConfidentialShard + pluggable logic)

**Did:** Refactored the monolithic `ConfidentialCounter` into a frozen, logic-agnostic
framework (`ConfidentialShard`) plus pluggable logic classes. The confidential state
now carries `logic_class_hash`; the virtual `transition` `library_call`s the committed
logic's `step`; the on-chain `apply_transition` is unchanged (proof-binding + CAS) and
never sees the class hash. Added `CounterLogic` (upgradeable, checked `u128`) and
`ImmutableCounterLogic` (ratchet). Removed `contract.cairo`. Compiles (3 classes).

**Why / decisions (with the user):** Design "B" (library_call to a class hash), but the
class hash lives *inside the confidential commitment* rather than on-chain — so which
logic governs a shard is confidential and self-enforcing (CAS pins `old_root`, which
pins the class hash). Upgrades are self-governed by the logic (option a): `step` returns
its successor; a logic that always returns its own hash is permanently immutable (a
one-way ratchet). Bricking-by-bad-upgrade explicitly accepted. The framework must stay
frozen (no `replace_class`/admin/`root` setter) — load-bearing for the immutability guarantee.

**Blockers / surprises:** The library dispatcher shares `ILogicDispatcherTrait` (there is
no `ILogicLibraryDispatcherTrait`) — one import fix.

**State after:** Framework compiles; class hashes recorded in [`STATUS.md`](./STATUS.md).
Audit finding #1 (unbounded arithmetic) addressed in the reference logics via checked
`u128`; finding #2 (app-logic binding) is now handled by the commitment. Orchestration
still targets v1 and needs rewriting.

**Next:** Rewrite orchestration for the framework schema; fresh Sepolia deploy demoing a
logic upgrade + the immutability ratchet; snforge tests; re-audit the framework.

## 2026-07-02 — End-to-end SNIP-36 test on Sepolia

**Did:** Ran the full flow on Sepolia via the `strkd` wallet companion — created &
funded a test account, declared class `0x7c0bbb31…`, deployed
`ConfidentialCounter(genesis_root)` at `0x285b651f…`, proved the virtual
`transition` off-chain, and broadcast the proof-carrying `apply_transition`
(tx `0x21f86b1b…`). `get_root()` advanced genesis `0x5f345327…` → `0x976c9f3d…`.

**Why / decisions:** Concrete example state = minimal counter; anchor = plain
Poseidon commitment (DESIGN.md defaults). Added an off-chain pre-check
(`check_proof.mjs`) comparing `proof_facts[8]` to the recomputed message hash
*before* broadcasting, to avoid a reverting on-chain tx.

**Blockers / surprises:**
- Declare `Account: invalid signature` — turned out to be **our** bug (compact ABI
  string → node derives a different class hash). Fixed by sending the canonical
  spaced ABI. Verified this before concluding, so *no false bug report was filed*.
- Virtual-tx `resource_bounds`: over-generous (balance check) then `l1_gas: 0` too
  low (needs ~29 524). Tuned to fit.
- strkd prover initially rejected Starknet v0.14.3 — a real external blocker,
  reported to the user; resolved by a strkd update. Also needed a prover testnet
  RPC set in strkd Settings.

**State after:** All SNIP-36 `VERIFY` unknowns confirmed against a real proof;
contract comments + README updated to "verified on Sepolia." STATUS.md reflects
"verified, pending tests + audit."

**Next:** snforge unit/fuzz tests, then a `cairo-auditor` pass.

## 2026-07-01 — Scaffold written

**Did:** Wrote the Cairo pair (`transition` + `apply_transition`), shared types,
genesis constructor; and the orchestration scripts. Confirmed `scarb build` passes
and that `get_execution_info_v3_syscall` / `proof_facts` exist in corelib 2.18.

**Why / decisions:** Bound the unconfirmed SNIP-36 details (`proof_facts` indices,
message-hash formula, `to_address`) as named `VERIFY`-marked constants so there was
one place to fix each. Verified SNIP-36 details against the reference impl first;
found its examples recompute results on-chain rather than reading `proof_facts`,
leaving those specifics unverified until the Sepolia run.

**State after:** Compiles; unverified on live network.
**Next:** Run it against Sepolia to confirm the `VERIFY` items.

## (pre-2026-07-01) — Design settled

**Did:** Architecture designed and captured in [`../../DESIGN.md`](../../DESIGN.md):
off-chain state, single Poseidon anchor, SNIP-36 virtual proving, on-chain
verify + compare-and-swap. **State after:** design settled, no code. **Next:** scaffold.
