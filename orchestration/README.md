# Orchestration — generic framework SDK

Drives the confidential shard framework off-chain. **Logic-agnostic:** the counter and
private claim are examples (`src/examples/*.ts`); swap in another `Example` to drive a
different application through the same framework.

```
src/
├── framework.ts          # generic SDK: commit(), transitionCalldata(), decode/serialize
│                         #   PublicMessage, computeMessageHash(), checkProof().
│                         #   Encodings are byte-identical to src/framework.cairo.
├── strkd.ts              # strkd wallet-companion client (pair, fund, declare, signAndProve, addInvoke)
├── rpc.ts                # read-only RPC helpers + class-hash / RPC-contract-class builders
├── examples/
│   ├── types.ts          # generic Example interface consumed by the driver
│   ├── counter.ts        # immutable dummy (app_state=[count]; public_input=[step])
│   ├── private_claim.ts  # confidential allowlist claim (private table; public_input=[claimant])
│   └── private_claim.test.ts  # node:test parity check: nextState ↔ Cairo step vectors
└── orchestrate.ts        # generic driver, parameterized by an Example (counter wired in main())
```

## The flow (per transition)

```
build transitionCalldata(public_input, ShardState)   // ShardState carries logic_class_hash
   → strkd.signAndProve  (Tx A, virtual; manual resource_bounds — never estimate)
   → waitProof → { proof, proof_facts, l2_to_l1_messages }
   → framework.checkProof   (off-chain: proof_facts[7]==1, [8]==compute_message_hash, roots)  ← pre-check before broadcasting
   → strkd.addInvoke apply_transition(msg) with { proof, proof_facts }  (Tx B)
   → rpc.waitForTx → read get_root()
```

Genesis is off-chain: `commit({ logic_class_hash, app_state₀, salt })`. **Declaring the
logic class is a prerequisite** — the prover `library_call`s it, so it must exist at the
reference block.

## Add a new application (make your own "counter")

Implement an `ILogic` class in `src/logics/…cairo`, declare it, then write an `Example`:

```ts
export function myExample(logicClassHash: bigint): Example {
  return {
    name: "my-app",
    logicClassHash,
    genesisState: (salt) => ({ logicClassHash, appState: /* encode initial state */ [], salt }),
    buildPublicInput: (action) => /* encode action */ [],
    nextState: (prev, action, newSalt) => /* mirror ILogic::step */ prev,
    describe: (s) => /* human view */ "",
  };
}
```

Pass it to the driver instead of `counterExample`. `framework.ts` never changes.

Because `nextState` must mirror your Cairo `step` exactly (the pre-broadcast `new_root`
check depends on it), add a `*.test.ts` next to your example asserting the mirror against
the same vectors your Cairo tests use — see `examples/private_claim.test.ts`.

## Non-negotiables

- **Never fee-estimate the virtual or proof-carrying tx** — set `resource_bounds` manually.
  The prover executes the virtual tx and enforces the account balance against these.
- **Canonical ABI on declare** (`rpc.rpcContractClass` handles it) or the node derives a
  different class hash → misleading `invalid signature`.
- Server-side only: private inputs and the token never reach a browser.

## Run

```bash
cp .env.example .env      # fill strkd URL/token, account, salt
npm install
npm run typecheck         # tsc --noEmit
npm test                  # node --test: example ↔ Cairo parity (private_claim.test.ts)
npm run orchestrate       # prints genesis/address; drive the strkd steps (each prompts)
```

Requires Node 22+ (`--experimental-strip-types`) and a running strkd companion with a
configured prover. See [`../docs/code/orchestration.md`](../docs/code/orchestration.md).
