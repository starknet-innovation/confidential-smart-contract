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
Scarb / Cairo **2.18**. `scarb build` emits three classes: `ConfidentialShard`,
`CounterLogic`, and `PrivateClaimLogic`.

## Types & interfaces (`src/interfaces.cairo`)

| Item | Shape | Role |
|------|-------|------|
| `ShardState` | `{ logic_class_hash: felt252, app_state: Array<felt252>, salt: felt252 }` | The full confidential state. `logic_class_hash` names the governing logic (lives *inside* the commitment). `salt` = blinding. Passed only as `private_input`. |
| `PublicMessage` | `{ old_root, new_root, outputs: Array<felt252> }` | The public claim; the L2→L1 payload = `Serde(PublicMessage)`, re-supplied as `apply_transition` calldata. |
| `IShard` | `transition`, `apply_transition`, `get_root` | The frozen framework interface. |
| `ILogic` | `step(logic_class_hash, app_state, public_input) -> (next_logic_class_hash, new_app_state, outputs)` | The pluggable-logic interface. `step` must be pure (no storage, no messaging). Returns its chosen successor class hash. |

## Framework (`framework.cairo` — `ConfidentialShard`)

**Storage:** `root: felt252` — the entire on-chain footprint. No `count`, no
`logic_class_hash` slot; nothing about the state or the logic is on-chain.

**`transition` (VIRTUAL, proven off-chain):**
```
// transition(public_input, private_input, new_salt)
destructure private_input -> (logic_class_hash, app_state, salt)
old_root = commit(logic_class_hash, app_state, salt)          // binds class hash to anchor
(next, new_app_state, outputs) = ILogicLibraryDispatcher{class_hash: logic_class_hash}
                                    .step(logic_class_hash, app_state, public_input)
assert next != 0                                              // cheap brick-guard
assert new_salt != 0                                          // per-transition salt rotation (guard)
new_root = commit(next, new_app_state, new_salt)              // FRESH caller-supplied salt
emit L2->L1 message = Serde(PublicMessage{old_root, new_root, outputs})
```
The class hash comes from `private_input` (the committed preimage), **never** from
`public_input` — that invariant is what makes the logic tamper-proof. `library_call`
runs the logic in the framework's context, so the message's `from_address` is the
framework (preserving the on-chain binding). The framework is the **sole emitter**;
a logic that emits its own message makes `proof_facts[7] != 1` → fail-closed.

**`apply_transition` (ON-CHAIN, proof-carrying):** structurally identical to v1 and
**logic-agnostic** — it never sees `logic_class_hash`.
```
read proof_facts via get_execution_info_v3_syscall
assert proof_facts[7] == 1
assert proof_facts[8] == compute_message_hash(get_contract_address(), msg)
assert msg.old_root == root  (CAS);  root := msg.new_root
emit Transitioned{old_root, new_root}
```

**`commit`** hashes `[logic_class_hash, app_state.len, ...app_state, salt]` (length
prefix prevents split ambiguity). Must be byte-identical off-chain.

**Do not add** `replace_class`, an owner, or a `root` setter to the framework —
freezing it is what makes a shard's logic-immutability guarantee real.

## Reference logics (`src/logics/`)

- **`CounterLogic`** — the minimal reference/dummy logic. `app_state=[count]`,
  `public_input=[step]`; increments with **checked `u128`** arithmetic (audit finding
  #1: no felt wraparound). **Immutable**: `step` always returns its own class hash and
  ignores any extra `public_input`, so a shard on this logic can never change logic
  (only `count` evolves). No reference logic ships an upgrade path (audit finding #2);
  an upgradeable logic would return a *different*, self-gated successor from `step`.
- **`PrivateClaimLogic`** — a richer immutable example. `app_state` is
  `[total_claimed, n, account_0, allocation_0, claimed_0, ...]`; `public_input` is
  `[claimant]`. A successful transition proves the claimant is in the private table,
  has not claimed yet, and receives exactly its allocation. The allowlist,
  non-claimants, and unclaimed allocations remain unpublished; outputs are
  `[claimant, allocation, total_claimed_after]`.

## Class hashes (this build)

| Class | Hash |
|-------|------|
| `ConfidentialShard` | `0x57e64f78bccd4ccecfc18b8f86d31a7739f17432cdbbb50b05ace9b0e231144` |
| `CounterLogic` | `0x4c5c6dcbf512c0e1caf1a72e12f5d94b38d38818391cec90ecf3f26f7b331e8` |
| `PrivateClaimLogic` | `0x2164b09fa1b2215e42acb359bc9ec75d18505f0f5c3d57c049bfffa79f0157` |

## Build & test

```bash
scarb build            # compiles (3 classes)
snforge test           # 11 tests
```
