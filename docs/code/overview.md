# Code Overview

> Map of the codebase. Read this first, then dive into [`cairo.md`](./cairo.md)
> (the on-chain + virtual Cairo) or [`orchestration.md`](./orchestration.md)
> (the off-chain client that drives proving and submission).
>
> For *why* the system is shaped this way, see [`../../DESIGN.md`](../../DESIGN.md)
> — the architecture source of truth. This doc describes *what the code actually is*.

## What the code implements

A **confidential counter shard**: a Starknet contract whose state (a counter)
lives **off-chain and is published nowhere**, anchored on-chain by a single
Poseidon commitment (`root`). State transitions are computed and **proven
off-chain via SNIP-36**; on-chain the contract only verifies the proof output
and compare-and-swaps the anchor.

It was run **end-to-end on Sepolia** (see [`../project/LOG.md`](../project/LOG.md)),
which confirmed the SNIP-36 details the design could not settle statically.

## The three parts

| Part | Where | Role |
|------|-------|------|
| **Virtual `transition`** | `src/contract.cairo` | Proven off-chain inside the SNIP-36 prover. Computes `new_root` from the confidential pre-state and emits `{old_root, new_root, step}` as an L2→L1 message. Never broadcast. |
| **On-chain `apply_transition`** | `src/contract.cairo` | A real tx carrying `{proof, proofFacts}`. Verifies the proof↔message binding and CAS-advances `root`. |
| **Orchestration** | `orchestration/` | Off-chain client (TypeScript / Node) that builds the virtual tx, drives proving, decodes the message, and broadcasts the verifier tx. |

Both Cairo entrypoints live on **one class at one address**, so
`get_contract_address()` matches between the virtual emit and the on-chain
recompute.

## File tree

```
confidential-smart-contract/
├── Scarb.toml                    # Cairo package (allowed-libfuncs = "all")
├── src/
│   ├── lib.cairo                 # module declarations
│   ├── interfaces.cairo          # shared types + ICounterShard trait
│   └── contract.cairo            # ConfidentialCounter (transition + apply_transition)
├── orchestration/
│   ├── package.json              # Node/TypeScript deps (starknet.js)
│   ├── .env.example              # config template
│   ├── README.md                 # orchestration-specific notes
│   ├── src/
│   │   ├── orchestrate.ts         # idealized standalone flow (proof server + starknet.js fork)
│   │   └── requestProof.ts        # SSE client for a proof server
│   └── scripts/                   # the ACTUAL strkd-companion flow used on Sepolia
└── docs/                          # you are here
```

## End-to-end data flow

```
 off-chain (secret)                          Starknet (Sepolia)
 ┌───────────────────┐
 │ PreState{count,   │  private_input
 │          salt}    │──────────────┐
 └───────────────────┘              ▼
                          ┌──────────────────────┐  proof + proof_facts
                          │ SNIP-36 prover        │  + L2→L1 message
                          │ runs virtual          │──────────────────────┐
                          │ transition()          │  {old_root,new_root,  │
                          └──────────────────────┘   step}                ▼
                                                            apply_transition:
   root: felt252  ◀────────────────────────────────────────  assert proof_facts[8]
   (the only                                                    == compute_message_hash
    on-chain state)                                            assert old_root == root  (CAS)
                                                               root := new_root
```

See [`orchestration.md`](./orchestration.md) for the concrete script-by-script
sequence, and [`cairo.md`](./cairo.md) for the contract internals.
