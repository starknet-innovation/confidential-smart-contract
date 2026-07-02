# Cairo Contract

> The on-chain + virtual Cairo. Files: `src/lib.cairo`, `src/interfaces.cairo`,
> `src/contract.cairo`. Package: `Scarb.toml`. For the design rationale see
> [`../../DESIGN.md`](../../DESIGN.md); for how it's driven see
> [`orchestration.md`](./orchestration.md).

## Package (`Scarb.toml`)

```toml
[[target.starknet-contract]]
allowed-libfuncs-list.name = "all"   # REQUIRED for get_execution_info_v3_syscall
```

`allowed-libfuncs = "all"` is mandatory: `get_execution_info_v3_syscall` (used to
read `proof_facts`) is not on the audited libfuncs list. Builds on Scarb / Cairo
**2.18**. Build with `scarb build`.

## Types (`src/interfaces.cairo`)

| Type | Fields | Role & calldata layout |
|------|--------|------------------------|
| `PreState` | `count: felt252`, `salt: felt252` | The confidential off-chain state. Passed **only** as `private_input` to the virtual `transition`. `salt` is a blinding factor so the commitment is *hiding*. Serializes as `[count, salt]`. |
| `Action` | `step: felt252` | Public action params. Serializes as `[step]`. |
| `PublicMessage` | `old_root`, `new_root`, `step` | The public claim the proof commits to. Emitted as the L2→L1 payload `[old_root, new_root, step]`, and re-supplied verbatim as `apply_transition` calldata. `Copy`. |

`ICounterShard` trait: `transition(public_input, private_input)`,
`apply_transition(msg)`, `get_root() -> felt252`.

## Contract (`src/contract.cairo` — `ConfidentialCounter`)

### Storage

```cairo
#[storage]
struct Storage {
    root: felt252,   // the ENTIRE on-chain footprint: one commitment
}
```

There is deliberately **no `count` slot**. The counter lives off-chain; on-chain
holds only `root = commit(state)`, which reveals nothing about `count`.

### `commit` and `compute_message_hash`

```cairo
fn commit(state: @PreState) -> felt252            // poseidon_hash_span([count, salt])
fn compute_message_hash(from, msg) -> felt252     // poseidon([from, to_address, len, ...payload])
```

**Determinism is load-bearing.** `commit`/serialization must be byte-identical to
any off-chain reconstruction (field order + Poseidon domain). Verified on Sepolia:
starknet.js `computePoseidonHashOnElements` reproduces Cairo `poseidon_hash_span`,
so the off-chain `genesis_root` matched the proof's `old_root`.

### `transition` — VIRTUAL (proven off-chain)

Self-attests `old_root = commit(private_input)`, computes `new_state`
(`count += step`), re-commits, and emits `[old_root, new_root, step]` as a single
L2→L1 message (`to_address = MSG_TO_ADDRESS = 0`). Reads no storage. Access posture:
intentionally public — mutates nothing; an on-chain call would only emit a message.

### `apply_transition` — ON-CHAIN (proof-carrying)

```cairo
1. exec = get_execution_info_v3_syscall(); proof_facts = exec.tx_info.proof_facts;
2. assert proof_facts[PROOF_FACTS_N_MSG_INDEX]  == 1                    // exactly one message
3. assert proof_facts[PROOF_FACTS_MSG_HASH_INDEX] == compute_message_hash(self, msg)  // proof↔message binding
4. assert msg.old_root == self.root.read()                             // message↔live-anchor CAS
   self.root.write(msg.new_root)                                       // (concurrency + replay guard in one)
5. emit Transitioned { old_root, new_root, step }                      // doubles as optional DA channel
```

Access posture: intentionally **public** — security is the proof↔message binding
plus the CAS, *not* caller identity. Only someone who knows the confidential
pre-state can produce a proof whose `old_root` matches the live anchor.

### Genesis

`constructor(genesis_root)` sets `root`. Because the state + salt are secret, the
genesis commitment is computed **off-chain** and passed in (asserted non-zero).

### SNIP-36 constants — VERIFIED on Sepolia (2026-07-02)

| Constant | Value | Meaning |
|----------|-------|---------|
| `PROOF_FACTS_N_MSG_INDEX` | `7` | `proof_facts[7]` = number of L2→L1 messages |
| `PROOF_FACTS_MSG_HASH_INDEX` | `8` | `proof_facts[8]` = Poseidon hash of the first message |
| `MSG_TO_ADDRESS` | `0` | L2→L1 `to_address`, used in both the virtual emit and on-chain recompute |

Confirmed against a real proof (ref block ~11480759, Starknet v0.14.3):
`proof_facts` had 9 felts, `[7] == 1`, and `compute_message_hash` reproduced
`proof_facts[8]` exactly. These were previously unconfirmed vs the reference impl
(whose examples recompute results on-chain instead of reading `proof_facts`).

## Build & test

```bash
scarb build            # compile
snforge test           # tests (not yet written — see ../project/STATUS.md)
```
