# Orchestration SDK

> The off-chain TypeScript SDK that drives the framework's SNIP-36 flow. It is
> **generic** and **logic-agnostic**: an app is a typed `Logic<State, Action>` plugged
> into a lifecycle `Shard` handle, over a pluggable execution backend. The counter and
> committee are two reference apps. Lives in `orchestration/`. For the Cairo it targets
> (and the logic authoring kit) see [`cairo.md`](./cairo.md).

## Layout

| File | Role |
|------|------|
| `src/index.ts` | Public API barrel — the single import surface. |
| `src/encoding.ts` | **Pure offline core.** `commit`, `transitionCalldata`, `serialize/decodePublicMessage`, `serializeActions`/`hashActions`, `consumeCalldata`, `shardConstructorCalldata`, `depositCalldata`, `registerIntentCalldata`, `computeMessageHash`, `checkProof`, `freshSalt`, `hex`. Byte-identical to `src/framework.cairo`. |
| `src/logic.ts` | **The app-author boundary:** the typed `Logic<State, Action>` interface + `defineLogic`. Mirrors your Cairo `ILogic::step`. |
| `src/backend.ts` | **The pluggable seam:** `ShardBackend` (`prove`, `apply`, `invoke`, `getRoot`, `waitForTx`) + `ProofResult`. |
| `src/shard.ts` | **The lifecycle handle:** `Shard<S,A>` (owns confidential state; `.transition`, `.deposit`, `.registerIntent`), plus `deployShard`, `attachShard` (resume), `genesisOf`, `shardAddress`. |
| `src/strkd.ts` | Raw `strkd` wallet-companion JSON-RPC client (pair, fund, declare, `signAndProve`, `waitProof`, `addInvoke`). |
| `src/strkd-backend.ts` | `StrkdBackend` — the reference `ShardBackend`. Owns prover policy: reference-block choice, virtual-tx nonce, and **manual** resource bounds. |
| `src/rpc.ts` | Read-only RPC helpers + `classHashOf` / `rpcContractClass` (canonical spaced ABI). |
| `src/apps/counter.ts` | The counter as `Logic<CounterState, CounterAction>` — the minimal immutable reference. |
| `src/apps/committee.ts` | The committee as `Logic<CommitteeState, CommitteeAction>` + SNIP-12 `approvalTypedData`/`approvalMessageHash` helpers a member signs via `wallet_signTypedData`. |
| `src/apps/lending.ts` | Confidential P2P lending as `Logic<LendingState, LendingAction>` (take/close) + `offer()`, `loanActionTypedData`/`loanActionMessageHash` (SNIP-12 auth a party signs via `wallet_signTypedData`), `resumeState` (escape: decrypt the published state + verify `commit == root`), and pure `originationOk`/`owed`. Mirrors `LendingLogic` v2 (hidden LTV + escape hatch). |
| `src/crypto.ts` | Encrypted-state DA for the escape hatch — hybrid ECIES (P-256 ECDH + HKDF + AES-GCM, node webcrypto, no deps) encrypting a `ShardState` to every party's key, felt-encoded to ride through `outputs`. `genEncKeyPair`, `encryptState`, `decryptState`. |
| `src/orchestrate.ts` | Thin end-to-end demo built on the SDK (deploy a counter, drive two transitions). |

## The whole loop

```ts
import { StrkdBackend, Strkd, deployShard, freshSalt } from "confidential-shard-sdk";
import { counterLogic } from "confidential-shard-sdk/apps/counter";

const backend = new StrkdBackend(new Strkd(url, token), account);
const { shard } = await deployShard({
  backend, frameworkClassHash, logic: counterLogic(logicClassHash),
  initial: { count: 0n }, salt: freshSalt(), deploySalt: 1n,
});

await shard.transition({ step: 1n });   // prove → pre-check → apply → (consume) → state++
console.log(shard.state);               // { count: 1n }  — typed
```

`shard.transition(action)` runs the entire per-transition flow and advances local state:

```
next state (off-chain mirror, fresh salt)          # via logic.next + logic.encodeState
  → backend.prove(transitionCalldata)              # Tx A (virtual; manual resource_bounds)
  → checkProof                                     # off-chain gate: [7]==1, [8]==msg hash, roots
  → backend.apply(applyTransitionCalldata, proof)  # Tx B: verify + CAS + record outbox
  → backend.getRoot → assert advanced
  → if msg.actions: backend.invoke(consume)        # Tx C: permissionless, one-shot, no proof
```

The driver skips Tx C when the logic emitted no actions (e.g. the counter). Genesis is
off-chain (`genesisOf` / `deployShard` compute the committed root). Re-attach to a running
shard with `attachShard(backend, logic, address, savedState)` to resume without redeploying.

## Adding another application

1. Write a Cairo `ILogic` class (start from `src/logics/template_logic.cairo`; use the
   `src/logic_kit.cairo` helpers) and **declare** it — the prover `library_call`s it.
2. Write a `Logic<State, Action>` mirroring it (see `src/apps/*.ts`): `encodeState`/
   `decodeState` ↔ your `app_state` layout, `buildPublicInput` ↔ your `public_input`,
   `next` ↔ your successor `app_state`. Upgradeable logics add `nextClassHash`.
3. `deployShard({ ..., logic })`, then `shard.transition(action)`.

`encoding.ts`, `backend.ts`, `shard.ts` never change — that is the point.

## Pluggable backend

`Shard` is written entirely against `ShardBackend`. `StrkdBackend` is the shipped
implementation; to run against a raw starknet.js account + self-hosted SNIP-36 prover,
implement the same five methods. The backend MUST set resource bounds manually — never
fee-estimate a virtual / proof-carrying tx, or its private calldata reaches an RPC node.

## Non-negotiables (unchanged from v1)

- Never fee-estimate the virtual / proof-carrying tx — set `resource_bounds` manually
  (the prover enforces the account balance against them). `StrkdBackend` does this.
- Canonical ABI on declare (`rpc.rpcContractClass`) or the node derives a different
  class hash → misleading `invalid signature`.
- Server-side only; the token and private inputs never reach a browser.

## Verify / run

```bash
cd orchestration && npm install
npm run typecheck        # tsc --noEmit  (clean)
npm run orchestrate      # dry-run: prints genesis/address. RUN_ONCHAIN=1 to deploy+transition.
```
