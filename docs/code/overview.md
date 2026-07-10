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
upgrades (and their own immutability). A logic may also **read public state** and emit
**public calls** (ERC-20 transfers, …) that the framework records to an **outbox** and a
permissionless `consume` executes later. See [`cairo.md`](./cairo.md) for the mechanism.

## The parts

| Part | Where | Role |
|------|-------|------|
| **`ConfidentialShard` framework** | `src/framework.cairo` | Frozen, address-pinned trust root. Virtual `transition` dispatcher + on-chain `apply_transition` verifier + CAS + outbox record; permissionless `consume` executes recorded public-call bundles; v4 **inbox** (`deposit` / `register_intent` + proven-read views) is the public → shard channel. Logic-agnostic. |
| **Logic classes** | `src/logics/` | Declared classes implementing `ILogic::step`, referenced by class hash from inside the committed state. `CounterLogic` = reference **immutable dummy** (no actions); `CommitteeLogic` = the outbox reference (confidential M-of-N committee emitting threshold-approved public calls, approvals verified in-proof). |
| **Types / interfaces** | `src/interfaces.cairo` | `ShardState`, `PublicCall`, `PublicMessage`, `InboxEntry`, `IShard`, `ILogic`, `IERC20`. |
| **Orchestration** | `orchestration/` | Generic off-chain client (logic-agnostic SDK + `Example`s): builds the virtual tx, drives proving, decodes the message, broadcasts `apply_transition`, then `consume` if the transition produced actions. |

## File tree

```
confidential-smart-contract/
├── Scarb.toml
├── src/
│   ├── lib.cairo                 # module declarations
│   ├── interfaces.cairo          # ShardState, PublicCall, PublicMessage, InboxEntry, IShard, ILogic
│   ├── framework.cairo           # ConfidentialShard (frozen dispatcher + verifier + outbox + inbox)
│   ├── logics/
│   │   ├── counter_logic.cairo   # CounterLogic (immutable dummy, checked u128, no actions)
│   │   └── committee_logic.cairo # CommitteeLogic (M-of-N in-proof approvals -> public calls)
│   └── mocks/
│       └── erc20_mock.cairo      # test-only MockERC20 (excluded from audit)
├── orchestration/                # off-chain client (generic SDK + counter/committee examples)
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
commitment + the proof. If the transition produced public `actions`, `apply_transition`
also records them to the outbox keyed by `new_root`; a later permissionless
`consume(new_root, actions)` re-supplies them (hash-checked, one-shot) and dispatches the
calls as the shard. In the other direction, `deposit` / `register_intent` append to the
on-chain **inbox**, which the confidential logic observes via proven reads
(`inbox_len` / `inbox_entry`) and consumes with a confidential cursor. See
[`cairo.md`](./cairo.md) and [`orchestration.md`](./orchestration.md).
