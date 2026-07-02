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
