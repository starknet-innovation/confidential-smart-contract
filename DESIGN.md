# Confidential Smart Contract — Design

> Source of truth for the architecture. Written from a design discussion; the code
> sketches are **pseudocode to verify against the SNIP-36 reference implementation**
> (github.com/starknet-innovation/snip-36-prover-backend), not copy-paste-ready.

## Purpose & trust model (read first)

**This is a showcase**, not a product track: it demonstrates what SNIP-36 virtual-block
proving makes possible — a confidential validium-style shard on Starknet. Decisions favor
clarity of mechanism; sharp edges are documented rather than fully engineered around.

**Participation models.** The framework supports two, chosen per shard by its logic:

- **Single-operator** (default; what the references demonstrate): one prover custodies the
  state and moves it. Confidential toward everyone else.
- **Multi-party shared private state**: private toward *outsiders*, NOT between
  participants — the whole-state commitment means every prover imports the full state.
  Requires the logic-level patterns in "Inbox (v4)": in-logic authorization
  (`CommitteeLogic` is the reference), encrypted on-chain DA, and inbox exit intents.
  Unilateral exit exists only for logics that adopt them (no DA publishing ⇒ no exit
  guarantee).

**Trust assumptions, accepted knowingly (2026-07-03):**

1. **SNIP-36 proofs are aspirationally ZK** — not yet formally witness-hiding. The
   confidentiality claim currently also rests on the proof itself not being analyzed;
   expected to strengthen as SNIP-36 evolves toward ZK.
2. **The prover is self-hosted by the operator.** A hosted prover sees the full state.
3. **Phase-1 verification is sequencer-side** — a malicious sequencer can write a forged
   root and drain shard-held funds via the outbox. No real value under Phase 1.
4. **Metadata is not hidden.** Application identity (behavioral fingerprinting of message
   shapes), transition timing, deposits/intents, and all public effects are visible.
   What IS confidential: state contents, decision inputs, and (for the committee) who
   approved.

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

## Generic framework (v2): frozen dispatcher + confidential pluggable logic

v1 fused the transition logic into the deployed class. v2 makes the logic **pluggable
and confidential** while keeping the on-chain verifier unchanged.

- **State gains a logic pointer:** `ShardState = { logic_class_hash, app_state[], salt }`,
  `root = commit(logic_class_hash, app_state, salt)`. The logic identity lives *inside*
  the commitment — never on-chain. `salt` is **rotated every transition**: each
  `transition(public_input, private_input, new_salt)` commits the successor under a
  fresh, caller-supplied high-entropy `new_salt`, so recovering one transition's salt
  cannot deanonymize any other (framework asserts `new_salt != 0`).
- **Frozen framework** (`ConfidentialShard`): the virtual `transition` reads
  `logic_class_hash` from the committed `private_input` and `library_call`s its `step`;
  the on-chain `apply_transition` is the v1 verifier unchanged (proof-binding + CAS) and
  never sees the class hash.
- **`ILogic::step(logic_class_hash, app_state, public_input) -> (next_logic_class_hash,
  new_app_state, outputs, actions)`** — no storage writes, no messaging; **may read** public
  state (see v3 below). The logic returns its successor (same hash = self-perpetuate,
  different = upgrade) and a list of public `actions` to execute (empty for a pure logic).

**Enforcement is cryptographic, not an on-chain check:** the CAS pins `old_root` to the
live anchor, and `old_root` pins `logic_class_hash` (a prover can't swap logic without
breaking Poseidon preimage resistance). Read the class hash from `private_input`,
**never** `public_input` — the load-bearing invariant.

**Self-governance + immutability ratchet.** The framework never chooses the successor; it
relays whatever the logic returns. So a logic fully governs its own mutability: one that
always returns its own hash is **permanently immutable** (one-way — becoming mutable would
require an upgrade the immutable logic refuses), while its state keeps evolving. This holds
ONLY if the framework stays frozen: **no `replace_class`, no admin, no `root` setter** —
otherwise an immutable logic could be bypassed. The shipped reference logic (`CounterLogic`)
is itself immutable; **no reference ships an ungated upgrade path** — an upgradeable logic
must gate its own successor (signature/quorum/allow-list).

**Accepted risks.** Bricking by a bad upgrade (undeclared/incompatible successor →
permanent fail-closed stall; framework only asserts `next != 0`). Which-logic privacy rests
on salt entropy + the public set of declared logics (declaring is public — you hide the
binding, not the code). The framework is the sole L2→L1 emitter; a logic that emits makes
`proof_facts[7] != 1` → fail-closed.

---

## Public interaction (v3): reading public state + an outbox of public calls

The confidential shard is also a real on-chain account: it can hold ERC-20s and act on
other contracts. v3 lets a private transition **read public state** and **trigger public
calls**, without touching the frozen verifier's soundness.

**Reading public state (reactive logic).** SNIP-36 proves the virtual `transition` against
a **reference block**, so any view the logic reads during proving (an oracle price, the
shard's own balance) is executed against that block and covered by the proof. `ILogic::step`
is therefore allowed to *read* (call other contracts' views) — it still must not write
storage or emit messages (sole-emitter). **Freshness is not the framework's job:** a logic
can bound the freshness of what it reads *relative to the reference block*, and SNIP-36
bounds how old the reference block itself may be. What no logic can self-impose is a tighter
bound on the *reference→apply* gap (the logic doesn't run at apply time); a shard needing
that would use its own framework variant.

**Triggering public calls (the outbox).** The virtual `transition` can't itself mutate other
contracts — it only produces a proof + one L2→L1 message. So the logic emits the calls it
wants as `actions: Array<PublicCall>` inside the (single, hash-bound) `PublicMessage`.
Execution is **decoupled from the root advance**, mirroring Starknet's own L2→L1 outbox:

- `apply_transition` verifies the proof, CASes the root, and **records** the action bundle to
  an on-chain outbox (`outbox[new_root] = poseidon(Serde(actions))`) — a commitment, not the
  calldata. It does **not** execute.
- A separate, **permissionless** `consume(new_root, actions)` re-supplies the bundle, checks
  it against the stored commitment, clears the entry (CEI/one-shot), then dispatches each call
  via `call_contract_syscall`. Anyone can relay it (like `consumeMessageFromL2`).

Why an outbox rather than executing inline+atomically:

- **The root always advances** — confidential progress never blocks on external settlement
  (an underfunded shard still transitions; the payout waits in the outbox and can be retried
  without re-proving).
- **Gas/DoS bounded** — recording is cheap; execution is a separate, amortizable tx.
- **Ordering** is preserved *within* a transition (one bundle = one `consume`, run in order).

The cost, accepted by design: **no cross-domain atomicity.** The confidential ledger can
believe "paid" while an outbox entry never settles. Keeping the ledger honest is a **logic**
choice, not the framework's — and a naive reference-block balance check is NOT enough: that
balance still includes funds committed to earlier **unconsumed** outbox entries, so
consecutive transitions can over-commit the same funds. Honest reserved-balance accounting
additionally *observes settlement* through the `outbox_of` view (v4): track
emitted-but-unsettled bundle keys in app_state, prove which have cleared, and only commit
what remains covered. **The framework is deliberately agnostic** — it records and replays
proven bundles; it never inspects what they do or whether the logic did tight accounting.
The shipped outbox reference is **`CommitteeLogic`** — a confidential M-of-N committee
whose threshold-approved decisions emit arbitrary public calls. It is **account-abstraction
native**: members are Starknet *accounts*, and each approval is a **SNIP-12** typed message
verified *in-proof* via the member account's SRC-6 `is_valid_signature` (so a member may
authenticate however its account does — stark key, multisig, passkey — and the orchestrator
never handles keys; members sign with the standard `wallet_signTypedData`). Approvals ride
in `public_input`, which only the prover sees: WHO approved stays confidential; only the
resulting calls become public.

**Authority is intrinsic, not escalated.** `consume` executes each call as the shard itself
(`get_caller_address()` at the target = the shard), so a shard can only exercise on-chain
authority it already holds (its own balances/approvals). Actions are commitment-bound (inside
`proof_facts[8]`), so a prover can't forge/edit them; `consume` is one-shot and self-call is
rejected; the frozen-framework invariant is intact (`consume` only ever replays a bundle a
verified transition recorded — it is not a `root` setter). **Confidentiality boundary:** any
public call *is public* (recipient + amount are visible on-chain); what stays confidential is
the ledger/decision that produced it, not the external effect.

**Deposits (public → shard)** are handled by the planned **inbox** — see v4 below.

---

## Inbox (v4 — implemented): deposits, intents, exit fairness

> Status: **implemented 2026-07-03** (`deposit` / `register_intent` / `inbox_len` /
> `inbox_entry` / `outbox_of`, the per-shard freshness gate (default off), and `outputs`
> echoed in `Transitioned`). Landed pre-freeze, as required — these could never have been
> added after the framework's first real deploy.

The inbox is the **dual of the outbox**: the outbox lets a confidential transition emit
public calls; the inbox lets public actors put facts *in front of* the confidential state,
trustlessly observable via proven reads. One primitive covers three needs: **deposits**,
**exit/withdraw fairness for multi-party shards**, and generic **public→private commands**.

**Framework surface** (append-only, globally ordered log; all policy-free):

- `deposit(token, amount, note)` — the framework itself executes
  `transferFrom(caller → shard)`, then appends
  `{seq, kind: DEPOSIT, caller, data: [token, amount.low, amount.high, note], block_number}`.
  Because the framework performed the transfer, the entry is *proof the funds arrived* —
  attribution a balance read can never provide (totals, not senders). `note` lets the
  depositor bind funds to a confidential identity (e.g. a commitment to a shard-internal key).
  Fee-on-transfer tokens: the recorded `amount` is the requested one; verifying the real
  delta is the logic's choice (reactive balance read).
- `register_intent(payload)` — appends `{seq, kind: INTENT, caller, data: payload,
  block_number}` (payload length-capped). The framework never interprets it.
- Views `inbox_len()` / `inbox_entry(seq)` — the **proven-read surface**: a logic reads
  entries during the virtual transition at the reference block, covered by the proof.

**Consumption is a confidential cursor, not a framework flag.** The framework never marks
entries consumed (that would leak processing activity and impose policy). A logic keeps
`inbox_seen` in its app_state and processes `(inbox_seen, inbox_len@ref]` each transition —
exactly-once and order-preserving by construction, invisible on-chain. Per-transition caps
and skip rules are logic policy.

**Spam.** Appending is permissionless (caller pays storage gas), but junk inflates honest
proving cost (logics read past it). Accepted initially, mitigated at logic level (processing
caps, dust thresholds for deposits); if insufficient, an anti-spam bond parameter is the
fallback — as a framework knob it must be decided **pre-freeze**.

**Exit fairness (multi-party logics).** The unilateral-exit guarantee becomes a logic rule:
*refuse to produce any transition whose reference block shows an unserviced intent older
than T*. The logic is commitment-pinned, so every valid transition enforces it — a griefer's
own transitions are forced to service your exit. The residual dodge — proving against a
reference block that *predates* the intent — is bounded only by reference-age enforcement:

**Escape hatch — realized in `LendingLogic` v2 (2026-07-09).** The two-party case has a
concrete implementation. Because `apply_transition`/`consume` are permissionless (security is
the proof↔message binding + CAS, not caller identity), the only barriers to a party settling
without the operator are *authorization* and *state availability*. The logic supplies both:
(1) every transition carries a **SNIP-12 signature** verified in-proof via the signer's
`is_valid_signature` — `close` accepts any of {operator, lender, borrower}, so Alice or Bob
can drive a settlement alone (the proven guards still own the *outcome*); (2) each transition
echoes the successor state **encrypted to every party's key** into `outputs` (the SDK's hybrid
ECIES), so a party recovers the state and self-proves, verifying `commit == new_root`. Expiry
liquidation lets the lender close a defaulted loan. Threat model = operator *absence* (a
garbage cipher is detectable, never a fund risk); in-circuit encryption would harden it
against a *malicious* operator. See `src/logics/lending_logic.cairo`.

**Reference-age enforcement (RESOLVED on Sepolia 2026-07-06).** SNIP-36 has a freshness
notion, but *where it is enforced is load-bearing*: prover-side checks are worthless in this
threat model because provers are self-hosted (an adversary patches them out); only the
on-chain verifier checking `proof_facts[4]/[5]` against the inclusion block counts. The
experiment settled it: **`proof_facts[4]` is exactly the reference block number** (and `[5]`
its block hash), and **a proof built against a 118-block-old reference (~1h) was accepted at
apply time on a gate-off shard** — the protocol does NOT enforce a tight reference-age window.
Therefore the framework gate (`assert current_block - proof_facts[4] <= K`, per-shard
constructor param, `0` = disabled) is **mandatory** for the fairness rule above: without it a
self-hosted prover can chain transitions against an arbitrarily old reference block forever
(the virtual `transition` never reads the live root, so CAS does not force fresh reference
blocks). The gate index is confirmed correct; shards that need exit fairness must set K > 0.

**Encrypted DA is a logic pattern, not a framework feature (decided 2026-07-03).** A
multi-party logic that promises unilateral exit publishes the new state (or a diff)
encrypted under a group key in `outputs` — computed *inside the proof*, so the ciphertext
is hash-bound via `proof_facts[8]`: the root cannot advance without simultaneously
publishing correct ciphertext, making data-withholding impossible and turning the chain
into the encrypted backup. The framework **cannot** make this mandatory even in principle —
it never sees the state, so it cannot check that any ciphertext encrypts it; only the logic
can assert that, in-proof. The framework's only touch: echo `outputs` in the `Transitioned`
event so the DA channel is indexable (shipped in v4). Logics that don't want on-chain
footprint (e.g. single-operator shards) simply don't publish — like signer rotation, a
per-application policy with a stated trade-off: **no DA publishing ⇒ no unilateral-exit
guarantee.**

---

## Sharp edges (must handle)

1. **Concurrency is serialized; retries cost a proof.** Racing transitions on the same root:
   one reverts and must re-prove against the new root (~40–50s, ~18 GB RAM each). Fine for
   per-user / low contention. For high throughput, **batch multiple actions into one proof**.

2. **Data availability is 100% on you — biggest risk.** State lives only in `private_input`,
   published nowhere (not even in the on-chain tx). Lose it → anchor is useless → shard
   frozen. **Since v3 a shard can hold real assets (ERC-20s): DA loss then means those funds
   are permanently locked**, not just a stalled shard. Note the tension: "per-user state,
   each user custodies their own leaves" requires a Merkle anchor (touched-leaves import) —
   with the whole-state Poseidon commitment, every prover needs the *full* state, so the
   participants all see everything. Shared/global state needs an explicit DA plan (off-chain
   DA layer, or committed/encrypted state emitted on-chain). Decide before shipping.

3. **NEVER fee-estimate the virtual tx online — doubly critical here.** Estimation ships the
   full calldata to the RPC, and the calldata *is* the confidential state. Set `resourceBounds`
   manually (~2× current gas prices). (SNIP-36 pitfall `SNIP36_FEE_ESTIMATION_SENSITIVE`.)

4. **Proving cost scales with what you hash.** Whole-state commitment re-hashes everything per
   proof; switch to a Merkle tree if that gets heavy. Watch virtual-tx calldata size limits.

5. **Phase-1 security model.** SNIP-36 proofs are currently verified sequencer-side, not by
   SNOS — degraded trust vs native Starknet. Concretely: a sequencer that accepts a false
   proof can write a `root` whose preimage *it* chose, then drain any shard-held funds
   through the outbox via a "valid" transition from that root. Do not anchor real value
   under Phase 1.

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
