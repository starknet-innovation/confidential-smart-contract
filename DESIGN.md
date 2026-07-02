# Confidential Smart Contract — Design

> Source of truth for the architecture. Written from a design discussion; the code
> sketches are **pseudocode to verify against the SNIP-36 reference implementation**
> (github.com/starknet-innovation/snip-36-prover-backend), not copy-paste-ready.

## Goal

Run a smart contract whose **full state is kept off-chain and published nowhere**,
while Starknet holds only a tiny **anchor** (a commitment to the state) and verifies
**state transitions computed off-chain**. This is a confidential validium-style shard:

- On-chain: one storage slot `root: felt252` + a proof-verifying entrypoint.
- Off-chain: the actual state (key/values), held by the operator or the users.
- Compute: runs off-chain inside a **SNIP-36** proof, so the chain re-executes nothing.

SNIP-36 explicitly lists this as an intended use case: *"ZKThread or shard transitions:
prove `{old_root, new_root, ...}` before updating L2 state."*

---

## Key insight: you probably don't need a Merkle tree

In a non-SNIP-36 design, a Merkle tree exists to avoid two **on-chain** costs: shipping
the whole state as calldata (L1 data gas) and re-hashing it on-chain. **With SNIP-36 both
costs move off-chain into the prover** — the state is imported via `private_input`, which
never touches Starknet. On-chain, a full-state commitment and a Merkle root both cost one
felt.

So the only remaining question is: **how expensive is it to re-hash the whole state inside
each proof?**

- **State fits in one virtual tx, re-hashing per proof is fine** → **plain Poseidon
  commitment**: `root = poseidon(serialize(state))`. No Merkle library. Import whole state,
  verify commitment, compute, re-commit. **Start here.**
- **State large, few keys touched, re-hashing all of it is prohibitive** → **Merkle tree**,
  so proving cost is `O(touched × depth)` not `O(state size)`.

---

## Architecture

Three roles. The binding to the anchor happens **on-chain**, so the virtual function
never needs to read chain storage — it just claims an `old_root` and the chain decides if
that claim is live.

```
  off-chain state (secret)                     Starknet (on-chain)
  ┌──────────────────────┐                     ┌───────────────────────┐
  │ full key/value state │                     │  root: felt252 (anchor)│
  └──────────┬───────────┘                     └───────────┬───────────┘
             │ private_input (never published)             │
             ▼                                              │
  ┌──────────────────────┐   proof + proofFacts            │
  │ SNIP-36 prover        │   + public L2→L1 msg            │
  │ runs virtual          │────────────────────────────────▶ apply_transition:
  │ transition()          │   {old_root,new_root,outputs}     verify proof, CAS root
  └──────────────────────┘                                    root := new_root
```

### Virtual function (proven off-chain, never called on-chain)

Pure state-transition function that self-attests `old_root = commit(old_state)`.

```cairo
// VIRTUAL — runs only inside the prover.
// private_input: the full pre-state (or touched leaves+paths) — NEVER published anywhere
// public_input:  action params allowed to be public
fn transition(ref self: ContractState, public_input: Action, private_input: PreState) {
    let old_root = commit(@private_input);              // poseidon(serialize(state)) — or merkle root
    let (new_state, public_outputs) = apply(private_input, public_input);
    let new_root = commit(@new_state);

    // publish ONLY the public claim as the proof's output
    let mut payload = array![old_root, new_root];
    public_outputs.serialize(ref payload);
    send_message_to_l1_syscall(0, payload.span()).unwrap();   // to_address 0: no real L1 msg
}
```

### On-chain apply (real tx, proof attached via `{proof, proofFacts}`)

Verifies the proof **and** compare-and-swaps the anchor.

```cairo
fn apply_transition(ref self: ContractState, msg: PublicMessage) {
    let info = get_execution_info_v3_syscall().unwrap_syscall().unbox();
    let proof_facts = info.tx_info.unbox().proof_facts;

    // (1) proof ↔ message binding
    let h = compute_message_hash(get_contract_address(), @msg);
    assert(*proof_facts[8] == h, 'proof/msg mismatch');

    // (2) message ↔ live anchor binding — CAS. Concurrency + replay guard in one line.
    assert(msg.old_root == self.root.read(), 'stale root');
    self.root.write(msg.new_root);

    // (3) act on public outputs; emit event (doubles as a DA channel if wanted)
    self.emit(Transitioned { old_root: msg.old_root, new_root: msg.new_root });
}
```

`Scarb.toml` must set `allowed-libfuncs-list.name = "all"` for `get_execution_info_v3_syscall`.

### Why it's sound: two independent bindings

1. **Proof ↔ message:** `proof_facts[8] == poseidon(hash of the L2→L1 payload)` — the
   `(old_root, new_root, outputs)` are exactly what the proven computation produced.
2. **Message ↔ live anchor (CAS):** `msg.old_root == self.root.read()` — the transition was
   computed against the *current* anchored state. This single check gives **both**
   concurrency safety and replay protection (once the root advances, old proofs no longer
   match). A separate nullifier is unnecessary unless other replay vectors exist.

---

## Sharp edges (must handle)

1. **Concurrency is serialized; retries cost a proof.** Racing transitions on the same root:
   one reverts and must re-prove against the new root (~40–50s, ~18 GB RAM each). Fine for
   per-user / low contention. For high throughput, **batch multiple actions into one proof**.

2. **Data availability is 100% on you — biggest risk.** State lives only in `private_input`,
   published nowhere (not even in the on-chain tx). Lose it → anchor is useless → shard
   frozen. **Safe shape: per-user state**, each user custodies their own leaves. Shared/global
   state needs an explicit DA plan (off-chain DA layer, or committed/encrypted diffs emitted
   as events). Decide before shipping.

3. **NEVER fee-estimate the virtual tx online — doubly critical here.** Estimation ships the
   full calldata to the RPC, and the calldata *is* the confidential state. Set `resourceBounds`
   manually (~2× current gas prices). (SNIP-36 pitfall `SNIP36_FEE_ESTIMATION_SENSITIVE`.)

4. **Proving cost scales with what you hash.** Whole-state commitment re-hashes everything per
   proof; switch to a Merkle tree if that gets heavy. Watch virtual-tx calldata size limits.

5. **Phase-1 security model.** SNIP-36 proofs are currently verified sequencer-side, not by
   SNOS — degraded trust vs native Starknet. Know this before anchoring real value.

6. **Determinism discipline.** `commit()` / `serialize()` must be byte-identical between the
   Cairo virtual function and any off-chain reconstruction (field order, Poseidon). Same class
   of bug as the nullifier-domain-mismatch pitfall — one field-order difference silently breaks
   every proof.

7. **Genesis.** Initialize `root` on-chain to `commit(empty_state)` at deploy so the first
   CAS has a valid match.

---

## SNIP-36 mechanics (reference)

3-phase flow:
- **CREATE (off-chain):** build a signed `INVOKE_TXN_V3` calling `transition`; never broadcast.
  Requires the proof-enabled starknet.js fork.
- **PROVE:** `POST {blockNumber, tx}` → prover → `{proof, proofFacts, l2ToL1Messages}`.
  ~40–50s, ~18 GB RAM. `snip36 prove virtual-os --block-number N --tx-json tx.json --rpc-url URL --output out.proof`.
- **VERIFY (on-chain):** `account.execute(verifyCall, {proof, proofFacts})` — starknet.js
  fork appends `proof_facts_hash` to the v3 tx hash automatically.

`proof_facts` layout: `[7]` = number of L2→L1 messages; `[8]` = Poseidon hash of the first
message (the value we assert against). Reference impl:
`github.com/starknet-innovation/snip-36-prover-backend`. Spec:
`community.starknet.io/t/snip-36-in-protocol-proof-verification/116123`.

---

## Open decisions

1. **Concrete example state** for the first scaffold. Default: **private key→balance map with
   confidential transfers** (naturally per-user, sidesteps the DA problem).
2. **Anchor type:** plain Poseidon commitment (start) vs Merkle tree (only if proving cost forces it).
3. **DA plan** — per-user vs shared; the load-bearing decision.
4. **Target network** — Sepolia expected for first deploy; needs a v0.8+ RPC and a prover backend
   (~18 GB RAM) for proofs.

## Next steps

1. Pick the example state + confirm commitment-vs-tree.
2. Scaffold `transition` (virtual) + `apply_transition` (on-chain) Cairo, using
   `cairo-contract-authoring`; verify syscall/proof_facts details against the reference impl.
3. Scaffold starknet.js orchestration (manual `resourceBounds`, prove, decode message, execute),
   using `starknet-js`.
4. Tests with `cairo-testing`; then a `cairo-auditor` pass (unaudited crypto + confidential state
   = review before any value).

---

## Background (earlier in the discussion)

Two adjacent Starknet mechanisms came up before the design converged, for reference:
- **`library_call_syscall`** — run an already-declared class's logic in the caller's context
  (delegatecall analog); scoped to that call.
- **`replace_class_syscall`** — a contract swaps its own class hash for another declared class
  (native upgrade pattern); persistent. Guard it (owner/role) and reject zero class hash.

Neither is core to this design, but they're the primitives for "load declared code in a single tx."

## Libraries evaluated (if a Merkle tree is chosen)

- **Cartesian Merkle Tree — Nethermind** (`github.com/NethermindEth/cartesian-merkle-tree`,
  `scarbs.xyz/packages/cartesian_merkle_tree`): mutable key-value state, on-chain
  insert/remove/search, **membership + non-membership proofs**, Poseidon, embeddable component.
  ⚠️ unaudited. Best fit for mutable state.
- **OpenZeppelin `openzeppelin_merkle_tree`** (`docs.openzeppelin.com/contracts-cairo/2.x/api/merkle-tree`):
  verification-only (`verify_poseidon`/`verify_pedersen`/`verify_multi_proof`), audited. Pair with
  your own root-recompute for updates.
- **Alexandria `alexandria_merkle_tree`** (`scarb add alexandria_merkle_tree@0.10.0`): binary Merkle +
  `storage_proof` module. Unaudited.
- **HerodotusDev/cairo-mmr**: Merkle Mountain Range — only if state is append-only.
- Off-chain tree/proof building: `ericnordelo/strk-merkle-tree`, `PhilippeR26/starknetMerkleTree` (TS).

## Sources

- SNIP-36 spec — community.starknet.io/t/snip-36-in-protocol-proof-verification/116123
- SNIP-36 reference impl — github.com/starknet-innovation/snip-36-prover-backend
- Cartesian Merkle Tree — github.com/NethermindEth/cartesian-merkle-tree
- OpenZeppelin Cairo Merkle Tree — docs.openzeppelin.com/contracts-cairo/2.x/api/merkle-tree
- Alexandria — github.com/keep-starknet-strange/alexandria
- Starknet state (Merkle-Patricia tries, height 251) — docs.starknet.io/learn/protocol/state
