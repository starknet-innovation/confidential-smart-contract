# Cairo Contracts

> The on-chain + virtual Cairo. Files: `src/lib.cairo`, `src/interfaces.cairo`,
> `src/framework.cairo`, `src/logics/*.cairo`. Package: `Scarb.toml`. For the design
> rationale see [`../../DESIGN.md`](../../DESIGN.md); for how it's driven see
> [`orchestration.md`](./orchestration.md).

## Architecture: frozen framework + pluggable logic

The contract is split into a **generic frozen framework** and **swappable logic**:

- **`ConfidentialShard`** (`framework.cairo`) — the trust root. Deployed at one
  address, address-pinned, and deliberately **frozen** (no upgrade / admin / `root`
  setter). It commits to an opaque state and verifies transitions. Logic-agnostic.
- **Logic classes** (`logics/*.cairo`) — each a *declared* class implementing
  `ILogic::step`. A shard names its governing logic by **class hash stored inside
  the committed state**, and the framework `library_call`s it.

Which logic governs a shard is therefore **confidential** (the class hash is in the
commitment, not on-chain) and **self-enforcing** (the CAS pins `old_root`, `old_root`
pins the class hash via Poseidon). Logics choose their own successor, so they
**self-govern upgrades** — including opting into permanent immutability.

## Package (`Scarb.toml`)

`allowed-libfuncs = "all"` (required for `get_execution_info_v3_syscall`). Builds on
Scarb / Cairo **2.18**. Depends on `openzeppelin_utils` (SNIP-12 domain helpers for the
committee). `scarb build` emits `ConfidentialShard`, `CounterLogic`, `CommitteeLogic`, and
**test-only `MockERC20` + `MockAccount`** (`src/mocks/`, excluded from audit; present in
the build because they aren't `cfg`-gated).

## Types & interfaces (`src/interfaces.cairo`)

| Item | Shape | Role |
|------|-------|------|
| `ShardState` | `{ logic_class_hash: felt252, app_state: Array<felt252> }` | The full confidential state. `logic_class_hash` names the governing logic (lives *inside* the commitment). Passed only as `private_input`. **v5: no framework salt** — blinding, if wanted, is a logic-level `seed` inside `app_state` (see `salt_kit` / `da_kit`), so `step` is the sole author of every committed felt. |
| `PublicCall` | `{ to: ContractAddress, selector: felt252, calldata: Array<felt252> }` | A public Starknet call the shard executes (as itself) via the outbox. |
| `PublicMessage` | `{ old_root, new_root, outputs: Array<felt252>, actions: Array<PublicCall> }` | The public claim; the L2→L1 payload = `Serde(PublicMessage)`, re-supplied as `apply_transition` calldata. `actions` is proof-bound (inside the message hash). |
| `InboxEntry` | `{ kind, caller, block_number, data: Array<felt252> }` | One inbox record (v4). `kind` = `'DEPOSIT'` (`data = [token, amount.low, amount.high, note]`) or `'INTENT'` (raw payload). Read by logics via the `inbox_entry` proven view; never marked consumed on-chain. |
| `IERC20` | `transfer_from(sender, recipient, amount) -> bool` | Minimal token surface the framework needs (deposits + intent fee). |
| `IShard` | `transition`, `apply_transition`, `consume`, `deposit`, `register_intent`, `inbox_len`, `inbox_entry`, `outbox_of`, `get_root` | The frozen framework interface. |
| `ILogic` | `step(logic_class_hash, app_state, public_input) -> (next_logic_class_hash, new_app_state, outputs, actions)` | The pluggable-logic interface. `step` must not write storage or emit messages, but **may read** public state (proven against the reference block) — including the shard's own inbox/outbox views. Returns its successor class hash + the public actions to record. |

## Framework (`framework.cairo` — `ConfidentialShard`)

**Storage:** `root: felt252` + `outbox: Map<felt252, felt252>` + the v4 **inbox log**
(`inbox_size` + per-seq kind/caller/block/data maps) + per-shard genesis config
(`freshness_window`, `intent_fee_token/amount` — set once in the constructor, **no
setters**). `root` is the anchor; `outbox` maps a transition's `new_root` → a
**commitment** to its pending action bundle (`poseidon(Serde(actions))`, `0` =
none/consumed). The inbox stores raw entries (they are public inputs *to* the
confidential state, not confidential data); everything about the state itself stays
commitment-only.

**Constructor:** `(genesis_root, freshness_window, intent_fee_token, intent_fee_amount)`.
`freshness_window = 0` disables the reference-age gate (rely on the protocol bound);
a non-zero intent fee requires a non-zero token and is pulled to the shard itself on
`register_intent`. ⚠️ Do not deploy with a non-zero window until `proof_facts[4]` is
empirically confirmed (see DESIGN.md "Reference-age enforcement").

**`transition` (VIRTUAL, proven off-chain):**
```
// transition(public_input, private_input)     // v5: no new_salt param
destructure private_input -> (logic_class_hash, app_state)
old_root = commit(logic_class_hash, app_state)               // binds class hash to anchor
(next, new_app_state, outputs, actions) = ILogicLibraryDispatcher{class_hash: logic_class_hash}
                                    .step(logic_class_hash, app_state, public_input)
assert next != 0                                              // cheap brick-guard
new_root = commit(next, new_app_state)                        // step is sole author of the preimage
emit L2->L1 message = Serde(PublicMessage{old_root, new_root, outputs, actions})
```
The class hash comes from `private_input` (the committed preimage), **never** from
`public_input` — that invariant is what makes the logic tamper-proof. `library_call`
runs the logic in the framework's context, so the message's `from_address` is the
framework (and any state the logic reads is read *as* the framework). Still the **sole
emitter** — exactly ONE message (with the actions inside it); a logic that emits its own
makes `proof_facts[7] != 1` → fail-closed.

**`apply_transition` (ON-CHAIN, proof-carrying):** **logic-agnostic** — never sees
`logic_class_hash`. Over v1 it additionally **records** (does not execute) actions, gates
reference-age (if configured), and echoes `outputs` in the event (the indexable DA channel).
```
read proof_facts via get_execution_info_v3_syscall
assert proof_facts[7] == 1
assert proof_facts[8] == compute_message_hash(get_contract_address(), msg)
if freshness_window != 0:                                  // v4, default off
    assert current_block <= proof_facts[4] + freshness_window   // VERIFY [4] on Sepolia
assert msg.old_root == root  (CAS);  root := msg.new_root
emit Transitioned{old_root, new_root, outputs}
if msg.actions non-empty: outbox[new_root] = hash_actions(msg.actions); emit OutboxRecorded
```

**`consume` (ON-CHAIN, PERMISSIONLESS):** executes a recorded bundle. Not a general
"call anything" primitive — it can only replay a bundle a verified transition committed.
```
// consume(entry_key, actions)
stored = outbox[entry_key];  assert stored != 0        // 'nothing to consume'
assert hash_actions(actions) == stored                 // 'actions mismatch'
outbox[entry_key] = 0                                   // CEI: clear BEFORE calls (one-shot)
for a in actions: assert a.to != this ('self-call'); call_contract_syscall(a.to, a.selector, a.calldata)
emit OutboxConsumed
```

**Inbox (v4, ON-CHAIN, PERMISSIONLESS):** the public → shard dual of the outbox.
```
deposit(token, amount: u256, note):
    transfer_from(caller -> shard, amount)   // FRAMEWORK executes it: trustless attribution
    append {kind: 'DEPOSIT', caller, block, data: [token, low, high, note]}
register_intent(payload):                    // len <= 64; optional fee pulled to the shard
    append {kind: 'INTENT', caller, block, data: payload}
inbox_len() / inbox_entry(seq) -> InboxEntry // the proven-read surface for logics
outbox_of(entry_key) -> felt252              // settlement observability (0 = consumed/none)
```
Entries are append-only and never marked consumed — a logic keeps its own confidential
cursor (`inbox_seen` in app_state) and processes `(seen, inbox_len@ref]` per transition.

**`commit`** hashes `[logic_class_hash, app_state.len, ...app_state]` (length prefix
prevents split ambiguity; **v5: no trailing salt**). **`hash_actions`** =
`poseidon(Serde(Array<PublicCall>))`. Both must be byte-identical off-chain.

**Do not add** `replace_class`, an owner, or a `root` setter to the framework —
freezing it is what makes a shard's logic-immutability guarantee real. `consume` is not
such a setter (it only replays proven bundles and never touches `root`).

## Reference logics (`src/logics/`)

- **`CounterLogic`** — minimal reference/dummy. `app_state=[count]`, `public_input=[step]`;
  increments with **checked `u128`** (audit finding #1). **Immutable**: always returns its
  own class hash, ignores extra `public_input`, emits **no actions**. No reference ships an
  upgrade path (audit finding #2).
- **`CommitteeLogic`** — THE outbox reference: a confidential M-of-N committee whose
  threshold-approved decisions emit arbitrary public calls. **Account-abstraction native**:
  members are ACCOUNTS and approvals are verified via each member's SRC-6
  `is_valid_signature` (any signature scheme the account supports).
  `app_state=[nonce, threshold, n_members, member_addr_1..n]`;
  `public_input = Serde(Array<PublicCall>) ++ Serde(Array<MemberSig>)` where
  `MemberSig = {signer: ContractAddress, signature: Array<felt252>}`. Each approval is a
  **SNIP-12 typed message** (domain binds name/version/`chainId`; message binds `shard`,
  `nonce`, `calls_hash`), verified **in-proof** by calling the member account's
  `is_valid_signature` — a proven read, so member addresses never touch the chain. Requires
  ≥ threshold distinct valid members, then returns the calls as `actions`. Approvals ride
  in `public_input` (prover-only): WHO approved stays confidential. Immutable; no
  member-rotation path (a production variant gates rotation on the same machinery). The
  SNIP-12 hash is cross-checked against starknet.js by the `approval_hash_matches_offchain_snip12`
  test. Uses `openzeppelin_utils` for the SNIP-12 domain. **Blind-signing caveat:** the
  typed message carries `calls_hash`, not the decoded calls — the SDK derives it from the
  actual calls (see DESIGN / the doc comment).

- **`LendingLogic`** — the flagship inbox+outbox example: confidential P2P lending. One
  shard = one loan. **min/max LTV live in the commitment (hidden)** so the liquidation price
  can't be known in advance (kills liquidation-hunting); amounts are public. Transitions:
  OFFERED (Alice escrows USDC) → `take` (the **signer's own** collateral deposit is summed
  from the inbox — scoped to the signer so a dust front-run can't hijack the slot — and the
  proof enforces the hidden band `minLTV ≤ draw/(collateral·price) < maxLTV` reading the
  oracle in-proof, outbox pays Bob) → `close` (the ONE settle method; the branch is forced by
  proven facts — **repayment wins over expiry**: repaid ⇒ collateral→Bob, principal+interest→
  Alice; else price crosses hidden maxLTV or past due ⇒ liquidate: collateral→Alice, which
  reads the oracle and rejects a zero price). An OFFERED loan can also be `cancel`led by the
  **lender** (refund the escrow) before anyone takes it. Uses the
  `logic_kit` (`unseen_inbox`, `erc20_transfer_call`). Flat term interest + duration;
  liquidation is proof-enforced against the oracle. Loan shards SHOULD set
  `freshness_window > 0` (stale-price liquidation defense).
  **Escape hatch (v2):** every transition carries a **SNIP-12 signature** verified in-proof
  via the signer account's `is_valid_signature` (AA-native, same machinery as
  `committee_logic`) — `take` must be **borrower**-signed; `close` by **any of {operator,
  lender, borrower}**. So Alice or Bob can settle without the operator; the proven guards
  still constrain the *outcome* (a signature only says WHO acts). **State availability (v3 /
  v5, salt_kit):** the shard carries a high-entropy `seed` in `app_state` (blinding vs the
  public), shared with the parties. Since v5 the framework has NO salt, so `step` is the sole
  author of the commitment — any party who knows the terms (they agreed them) + the seed
  reconstructs every state and self-proves, **even against a MALICIOUS operator** (who has no
  free secret blinding to lock them out). `nonce` makes each authorization single-use and every
  `new_root` unique; the SNIP-12 domain binds the chain, the message binds the shard (no
  replay). SNIP-12 hash cross-checked against starknet.js by `loan_action_hash_matches_offchain_snip12`.
- **`PrivateRegisterLogic`** — the reference for **`da_kit`** (in-circuit encrypted DA): a
  confidential value blind parties learn ONLY by decrypting the sealed `outputs` (the case
  salt_kit can't cover — a party who can't reconstruct the state). `step` calls `da_kit::seal`
  to publish the successor encrypted to every party's stark key; a party `da_kit::open`s it
  off-chain (or in-proof) and verifies `commit == new_root`. Proven in-circuit ⇒ the operator
  can't broadcast garbage ⇒ malicious-operator-safe availability for blind parties.

## Authoring kit (`src/logic_kit.cairo`, `src/logics/template_logic.cairo`)

Optional convenience for writing new logics — **not** part of the frozen framework (no
contract, no storage, no trust surface). Import à la carte from `crate::logic_kit`:

- **`build_call(to, selector, calldata) -> PublicCall`** — construct an outbox call.
- **`erc20_transfer_call(token, recipient, amount: u256) -> PublicCall`** — the most common
  outbox action (the shard runs it AS ITSELF, so it moves only assets it holds).
- **`unseen_inbox(shard, seen) -> Array<InboxEntry>`** — read inbox entries `(seen, len]`
  (deposits/intents) as a **proven read** against the reference block; call it with
  `get_contract_address()` from `step` and advance your own confidential cursor.

**`TemplateLogic`** (`src/logics/template_logic.cairo`) is a heavily-commented copy-paste
skeleton implementing `ILogic::step`: it walks the five steps (decode state/input, validate,
emit actions, consume inbox, return successor) with example snippets. Copy it, rename, fill
in, then mirror your `app_state` / `public_input` layout in a TS `Logic<State, Action>`
(`orchestration/src/apps/*.ts`). The kit is covered by `tests/logic_kit.cairo`.

## Reusable kits (importable modules — not components; stateless, like OZ `snip12`)

- **`logic_kit`** — `build_call`, `erc20_transfer_call`, `unseen_inbox` (proven inbox read).
- **`salt_kit`** — deterministic blinding for hiding logics under v5: keep a high-entropy `seed`
  in `app_state` (`step` carries it); pass no framework salt. `rotate(seed, nonce)` for
  per-transition derived values. Malicious-operator-safe (the operator has no free blinding).
- **`crypto_kit`** — STARK-curve ECIES primitive: ECDH via the native `ec_op` builtin (recipient
  keys are stark account keys, x-coord only) + a Poseidon-CTR/MAC DEM. `~1.4M l2_gas` to seal a
  20-felt state to 3 parties (proving work, not on-chain gas). Cairo↔TS interop verified.
- **`da_kit`** — `seal`/`open` over `crypto_kit`: in-circuit encrypted DA for blind-party resume.

The framework itself is now the `ShardComponent` (`src/shard_component.cairo`); `ConfidentialShard`
is a thin frozen embedder, so an upgradeable variant can embed the same audited component.

## Class hashes (v5 build)

| Class | Hash |
|-------|------|
| `ConfidentialShard` (v5 component, no salt) | `0x25237b7d038cd9821bca3561b54ea46029d34efa1e7f047a60a728843019aee` |
| `CounterLogic` (transparent; unchanged) | `0x1acb3488cfe126eb7d06bdd445bed46006768097be9791f2632912921e5feb5` |
| `CommitteeLogic` (+ salt_kit seed) | `0x49b55f88a943cb37c482f959ca18926b5d2802f9f675882231d206f5ebf2105` |
| `LendingLogic` (v3, salt_kit; audit-fixed) | `0x5c6b46972d9c1e7e1d063feec5d11ef3d4d8cfc697547c2f553fd1c6bcdba6d` |
| `PrivateRegisterLogic` (da_kit example) | `0x51337bc0e6bee1afc916e4a44447e63cb4ef8d822b087d997a78339ada46ffe` |

Pre-v5 Sepolia deployments are on the old (v4) hashes — historical; new demos use the above.

## Build & test

```bash
scarb build            # compiles the classes above
snforge test           # 53 tests pass (framework/counter/committee/consume/inbox + lending v3
                       #   escape + audit-fix regressions + logic_kit + crypto_kit ECIES + PrivateRegister da_kit)
```
