# Project Status

> Current-state snapshot: what's done, in flight, next, risks. Keep current — see
> [`PROCESS.md`](./PROCESS.md). History is in [`LOG.md`](./LOG.md).

**Last updated:** 2026-07-07
**Phase:** Generic framework implemented, tested (11 snforge tests pass), audited (deep, both findings fixed), and given a generic orchestration SDK with counter + private-claim examples. v1 verified on Sepolia. Framework not yet deployed.
**One-line state:** Frozen framework + confidential pluggable logic; compiles, 11 tests pass, deep audit = 0 Critical/High and **both findings FIXED** (per-transition salt rotation; immutable reference logics — no ungated upgrade ships). Next: a fresh Sepolia deploy.

---

## Done ✅

- [x] Architecture designed and settled — see [`../../DESIGN.md`](../../DESIGN.md).
- [x] **v1 monolithic `ConfidentialCounter`** — verified end-to-end on Sepolia (declare → deploy → prove → apply_transition → CAS). Confirmed the SNIP-36 unknowns against a real proof.
- [x] Deep security audit of v1 — 0 Critical/High/Medium; 2 low-confidence notes (unbounded `count+step` arithmetic; proof under-binding to app logic).
- [x] **v2 generic framework** (`ConfidentialShard`) — frozen dispatcher + logic-agnostic verifier; confidential `logic_class_hash` in the committed state; `library_call` to the committed logic; self-governing upgrades + immutability ratchet. Compiles on Scarb/Cairo 2.18.
- [x] Reference logic: `CounterLogic` — an **immutable** dummy, checked `u128` (addresses finding #1); ships no upgrade path (addresses finding #2). (`ImmutableCounterLogic` merged away — now redundant.)
- [x] Reference logic: `PrivateClaimLogic` — an **immutable confidential allowlist claim** example. Private state carries `[total_claimed, n, account, allocation, claimed, ...]`; public input is `[claimant]`; outputs are `[claimant, allocation, total_claimed_after]`.
- [x] **Generic orchestration SDK** (`orchestration/src/`): `framework.ts` (logic-agnostic commit/calldata/message), `strkd.ts`, `rpc.ts`, `examples/types.ts`, `examples/counter.ts`, `examples/private_claim.ts`, `orchestrate.ts` driver. Typecheck clean; v1 `.mjs` scripts removed.
- [x] **snforge tests — 11 passing**: `CounterLogic` `step` (increment/self-perpetuate, immutability, u128-overflow revert) + `PrivateClaimLogic` `step` (eligible claim, double-claim rejection, missing-claimant rejection, u128-overflow revert) + framework `transition` (commit determinism + `library_call` dispatch + message + salt rotation + immutability-through-the-framework + private-claim dispatch + zero-salt rejection).
- [x] **Fixed both audit findings** — #1 salt reuse (per-transition rotation) and #2 ungated reference upgrade (`CounterLogic` made immutable); see Open audit findings.
- [x] **Deep re-audit of the framework** — 0 Critical/High; findings below. Confirmed: `library_call` can't spoof `from_address`, sole-emitter holds (`proof_facts[7]==1`), logic is commitment-pinned (not from public_input), framework is frozen. v1 finding #2 (app-logic binding) closed by the commitment.

## In progress 🔄

- _(nothing currently in flight)_

## Open audit findings 🔎 (framework, 2026-07-02)

1. **✅ FIXED (2026-07-02) — Medium (conf 78) constant salt reuse** (`framework.cairo`): `transition` now takes a caller-supplied `new_salt` and commits the successor under it (`assert new_salt != 0`), so every root uses an independent, fresh, high-entropy salt — recovering one no longer cascades. SDK generates it via `framework.ts freshSalt()`; a guard test (`transition_rejects_zero_new_salt`) + rotation assertions cover it.
2. **✅ FIXED (2026-07-02) — Low (conf 55) ungated upgrade in reference `CounterLogic`**: removed the upgrade path entirely — `CounterLogic` is now an immutable dummy (`step` always returns its own class hash, ignores extra `public_input`), and the redundant `ImmutableCounterLogic` was merged away. No reference logic ships an upgrade path. The framework still supports upgrades for a production logic that gates its own successor (signature/quorum/allow-list).

## Next / backlog 📋

1. **Fresh Sepolia deploy** of the framework: declare `ConfidentialShard` + example logics, `genesis_root = commit(...)`, deploy, prove, apply. Demonstrate **salt rotation** on-chain (the one path snforge can't cover — `apply_transition`'s proof_facts).
2. **DA plan for non-toy state** (unchanged from v1 — DESIGN.md sharp edges).
3. **(If/when upgrades are wanted)** ship a *gated* upgradeable logic (signature/quorum/allow-list) as a separate example — the framework supports it; no reference ships it today.

## Known risks / watch-items ⚠️

- **The framework MUST stay frozen** (no `replace_class`/admin/`root` setter). This is load-bearing: it's what makes logic-immutability real. Any future change here breaks the guarantee.
- **Bricking by bad upgrade is accepted** (user decision): a logic that returns a bad/undeclared/incompatible successor permanently stalls the shard (fail-closed). Framework only cheaply asserts `next != 0`.
- **Which-logic privacy** depends on salt entropy + the set of declared logics (declaring is public — you hide the binding, not the code).
- **Phase-1 SNIP-36 trust model** (sequencer-side verification) — unchanged.
- **Both audit findings fixed** (see "Open audit findings" above). Residual: `apply_transition`'s proof_facts path is network-only-testable (not snforge-covered), pending a Sepolia deploy.

## Artifacts

**v2 framework class hashes (current build):**

| Class | Hash |
|-------|------|
| `ConfidentialShard` | `0x57e64f78bccd4ccecfc18b8f86d31a7739f17432cdbbb50b05ace9b0e231144` |
| `CounterLogic` | `0x4c5c6dcbf512c0e1caf1a72e12f5d94b38d38818391cec90ecf3f26f7b331e8` |
| `PrivateClaimLogic` | `0x2164b09fa1b2215e42acb359bc9ec75d18505f0f5c3d57c049bfffa79f0157` |

**v1 monolithic deployment (Sepolia, historical):** contract `0x285b651f…`, class `0x7c0bbb31…`, account `0x04078aa8…` (see [`LOG.md`](./LOG.md)).
