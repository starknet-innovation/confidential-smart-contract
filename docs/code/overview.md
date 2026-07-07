# Code Overview

> Map of the codebase. Read this first, then dive into [`cairo.md`](./cairo.md)
> (the on-chain + virtual Cairo) or [`orchestration.md`](./orchestration.md)
> (the off-chain client). For *why* the system is shaped this way, see
> [`../../DESIGN.md`](../../DESIGN.md). This doc describes *what the code actually is*.

## What the code implements

A **confidential shard framework**: a Starknet contract whose state lives off-chain
(published nowhere), anchored on-chain by a single Poseidon commitment (`root`).
State transitions are computed and **proven off-chain via SNIP-36**; on-chain the
contract only verifies the proof output and compare-and-swaps the anchor.

The transition **logic is pluggable**: a shard names its governing logic by class
hash *stored inside the committed state*, and the framework `library_call`s it. So
which logic runs is confidential and self-enforcing, and logics self-govern their own
upgrades (and their own immutability). See [`cairo.md`](./cairo.md) for the mechanism.

## The parts

| Part | Where | Role |
|------|-------|------|
| **`ConfidentialShard` framework** | `src/framework.cairo` | Frozen, address-pinned trust root. Virtual `transition` dispatcher (proven off-chain) + on-chain `apply_transition` verifier + CAS. Logic-agnostic. |
| **Logic classes** | `src/logics/*.cairo` | Declared classes implementing `ILogic::step`, referenced by class hash from inside the committed state. `CounterLogic` = minimal immutable dummy; `PrivateClaimLogic` = confidential allowlist claim. |
| **Types / interfaces** | `src/interfaces.cairo` | `ShardState`, `PublicMessage`, `IShard`, `ILogic`. |
| **Orchestration** | `orchestration/` | Off-chain client that builds the virtual tx, drives proving, decodes the message, broadcasts the verifier tx. Generic SDK plus per-logic examples. |

## File tree

```
confidential-smart-contract/
├── Scarb.toml
├── src/
│   ├── lib.cairo                 # module declarations
│   ├── interfaces.cairo          # ShardState, PublicMessage, IShard, ILogic
│   ├── framework.cairo           # ConfidentialShard (frozen dispatcher + verifier)
│   └── logics/
│       ├── counter_logic.cairo           # CounterLogic (immutable dummy, checked u128)
│       └── private_claim_logic.cairo     # PrivateClaimLogic (confidential allowlist claim)
├── orchestration/                # off-chain client + per-logic examples
└── docs/                         # you are here
```

## End-to-end data flow

```
 off-chain (secret)                              Starknet
 ┌────────────────────────────┐
 │ ShardState {               │  private_input
 │   logic_class_hash,        │──────────────┐
 │   app_state…, salt }       │              ▼
 └────────────────────────────┘   ┌──────────────────────────┐
                                   │ SNIP-36 prover           │
                                   │  transition():           │  proof + proof_facts
                                   │   old_root = commit(...)  │  + L2→L1 message
                                   │   library_call(           │─────────────────────┐
                                   │     logic_class_hash,step)│  {old_root,new_root, │
                                   │   new_root = commit(...)  │   outputs}           ▼
                                   └──────────────────────────┘        apply_transition:
   root: felt252 ◀────────────────────────────────────────────────  assert proof_facts[8]
   (only on-chain state)                                                == compute_message_hash
                                                                       assert old_root==root (CAS)
                                                                       root := new_root
```

The logic class hash never appears on-chain; it is enforced entirely by the
commitment + the proof. See [`cairo.md`](./cairo.md) and
[`orchestration.md`](./orchestration.md).
