# Project Status

> The single source of truth for **where the project is right now**: what's done,
> what's in flight, what's next. Keep this current — see
> [`PROCESS.md`](./PROCESS.md) for the rules. Narrative history lives in
> [`LOG.md`](./LOG.md); this file is the *current-state snapshot*, not a diary.

**Last updated:** 2026-07-02
**Phase:** Verified on Sepolia. Not yet tested (unit) or audited.
**One-line state:** Full SNIP-36 round-trip proven on Sepolia; contract compiles;
next up is a test suite and a security audit before any real value.

---

## Done ✅

- [x] Architecture designed and settled — see [`../../DESIGN.md`](../../DESIGN.md).
- [x] Cairo scaffold: `ConfidentialCounter` (virtual `transition` + on-chain
      `apply_transition`), types, genesis constructor. Compiles on Scarb/Cairo 2.18.
- [x] Off-chain orchestration scripts (strkd-companion path).
- [x] **End-to-end test on Sepolia**: declare → deploy → off-chain prove →
      proof-carrying `apply_transition` → root advanced by CAS.
- [x] Verified the SNIP-36 unknowns against a real proof: `proof_facts[7]`=n_msgs,
      `[8]`=message hash, `poseidon([from,to,len,...payload])` formula, `to_address=0`,
      Poseidon determinism (off-chain == Cairo).

## In progress 🔄

- _(nothing currently in flight)_

## Next / backlog 📋

Ordered roughly by priority. Move an item to **In progress** when you start it
(and log it — see [`PROCESS.md`](./PROCESS.md)).

1. **Unit + fuzz tests** with `snforge` — `apply_transition` CAS/replay logic,
   `commit`/`compute_message_hash` determinism, genesis guard. Mock `proof_facts`
   via cheatcodes. _(Nothing verifies the contract in isolation yet.)_
2. **Security audit** (`cairo-auditor`) — unaudited crypto handling confidential
   state; do this before anchoring anything real.
3. **Concurrency / retry handling** in the client — racing transitions on the same
   root: one reverts (`'stale root'`) and must re-prove. Decide batching vs retry.
4. **Data-availability plan for non-toy state** — the counter sidesteps DA; a real
   per-user or shared shard needs an explicit DA decision (DESIGN.md §"Sharp edges").
5. **Standalone (non-strkd) orchestration** — wire `orchestrate.ts` to a real proof
   server + starknet.js fork, if moving off the companion.
6. **Merkle-tree anchor** — only if whole-state re-hashing per proof becomes too
   expensive (DESIGN.md §"Open decisions").

## Known risks / watch-items ⚠️

- **Phase-1 SNIP-36 trust model**: proofs are verified sequencer-side, not by SNOS.
  Degraded trust vs native Starknet — know this before anchoring value.
- **Prover ↔ protocol version**: strkd's prover must track the live Starknet version
  (it briefly couldn't handle v0.14.3; fixed by an update). Re-check after upgrades.
- **No tests / no audit yet** — treat the contract as unproven in isolation.

## Deployed test artifacts (Sepolia)

| Item | Value |
|------|-------|
| Contract | `0x285b651fce00a353b8f61eedbf157be0eac84384dc8ec90406feafca09007b0` |
| Class hash | `0x7c0bbb31ba309190606171f17745977c6fa94cc5575f83ec35d28e6a4e53f75` |
| Test account | `0x04078aa88fd37258ad019413af8ba35c509e701c984aaaa2c41c3834f4363906` |
| Current `root` | `0x976c9f3d…dac35` (after count 0→1) |

> Test state uses throwaway salt `0x1a2b3c4d5e6f7a8b` — **not** a pattern for real
> confidential state.
