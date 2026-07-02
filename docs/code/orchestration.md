# Orchestration

> The off-chain client that drives the framework's SNIP-36 flow. It is **generic**:
> the counter is one example plugged into a logic-agnostic SDK. Lives in
> `orchestration/`. For the Cairo it targets see [`cairo.md`](./cairo.md).

## Layout

| File | Role |
|------|------|
| `src/framework.ts` | Generic SDK. `commit`, `transitionCalldata`, `serialize/decodePublicMessage`, `computeMessageHash`, `checkProof`. Encodings are byte-identical to `src/framework.cairo`. |
| `src/strkd.ts` | `strkd` wallet-companion client (pair, fund, deploy account, declare, `signAndProve`, `waitProof`, `addInvoke`). |
| `src/rpc.ts` | Read-only RPC helpers + `classHashOf` / `rpcContractClass` (canonical spaced ABI). |
| `src/examples/counter.ts` | The counter as one `Example` — an immutable dummy (app_state `[count]`; public_input `[step]`). |
| `src/orchestrate.ts` | Generic driver parameterized by an `Example`; `runTransition(...)` is the reusable core. |

## Flow (per transition)

```
transitionCalldata(public_input, ShardState, new_salt)  # fresh freshSalt() each call (salt rotation)
  → strkd.signAndProve            (Tx A, virtual; manual resource_bounds)
  → waitProof                     → {proof, proof_facts, l2_to_l1_messages}
  → framework.checkProof          # off-chain gate: [7]==1, [8]==compute_message_hash, roots
  → strkd.addInvoke apply_transition(msg) {proof, proof_facts}   (Tx B)
  → rpc.waitForTx → get_root()
```

Genesis is off-chain: `commit({logic_class_hash, app_state₀, salt})`. **Declaring the
logic class is a prerequisite** — the prover `library_call`s it.

## Adding another application

Write an `ILogic` Cairo class, declare it, and add an `Example` (see
`orchestration/README.md` for the shape). Pass it to the driver instead of
`counterExample`; `framework.ts` never changes. That is the point of the refactor —
the counter is not special.

## Non-negotiables (unchanged from v1)

- Never fee-estimate the virtual / proof-carrying tx — set `resource_bounds` manually
  (the prover enforces the account balance against them).
- Canonical ABI on declare (`rpc.rpcContractClass`) or the node derives a different
  class hash → misleading `invalid signature`.
- Server-side only; the token and private inputs never reach a browser.

## Verify / run

```bash
cd orchestration && npm install
npm run typecheck        # tsc --noEmit  (currently clean)
npm run orchestrate      # prints genesis/address; drive the strkd steps (each prompts)
```

**Not yet exercised on-chain for the framework** — a fresh Sepolia deploy demonstrating
a logic upgrade + the immutability ratchet is pending (see
[`../project/STATUS.md`](../project/STATUS.md)).
