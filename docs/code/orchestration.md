# Orchestration

> The off-chain client that drives the SNIP-36 flow: build the virtual tx →
> prove → decode the message → broadcast the verifier tx. Lives in
> `orchestration/`. For the Cairo it targets see [`cairo.md`](./cairo.md).

There are **two** orchestration paths in the repo, for two different setups:

| Path | Files | Status |
|------|-------|--------|
| **strkd companion** (used on Sepolia) | `orchestration/scripts/*.mjs` | ✅ the real, working flow |
| **Standalone** (proof server + starknet.js fork) | `orchestration/src/orchestrate.ts`, `requestProof.ts` | 📄 illustrative reference (matches DESIGN.md's original plan; not exercised) |

Pick the one that matches your environment. The Sepolia end-to-end test used the
**strkd companion** path; that is the canonical, verified sequence below.

## Prerequisites

- Node 22+ and `npm install` inside `orchestration/`.
- A running **`strkd`** wallet companion (holds keys, signs, and bundles the
  on-device SNIP-36 prover). Discover its URL and API via `GET /`.
- strkd Settings: a per-network **testnet RPC** configured for the prover, and a
  prover build that supports the current Starknet protocol version.
- A reliable public read RPC for status/balance queries
  (`https://api.cartridge.gg/x/starknet/sepolia` worked; several others were flaky).

## Non-negotiable rules

1. **Never fee-estimate the virtual tx.** Estimation ships the calldata — which
   *is* the confidential state — to an RPC node. Always set `resource_bounds`
   manually. (strkd refuses to estimate proof-carrying / virtual txs for this reason.)
2. **The prover executes the virtual tx**, so its `resource_bounds` must both cover
   actual gas (e.g. a transition used ~29 524 L1 gas — `l1_gas` can't be 0) *and*
   fit the account balance (`sum(max_amount × max_price) ≤ balance`).
3. **Canonical ABI for declares.** `contract_class.abi` must be the spaced form
   (`formatSpaces(json.stringify(abi))`), not compact `JSON.stringify`, or the node
   derives a different class hash → a misleading `Account: invalid signature`.
4. **Keep secrets server-side.** Private inputs and signing keys never touch a browser.

## The strkd flow (canonical sequence)

Each step's helper script is in `orchestration/scripts/`. Off-chain compute uses
starknet.js; wallet actions go through the strkd JSON-RPC over loopback HTTP.

| # | Step | Script(s) |
|---|------|-----------|
| 1 | Compute `genesis_root`, `new_root` from `(count, salt)` | `prep.mjs` |
| 2 | Compute `class_hash` + `compiled_class_hash` from the build | `hashes.mjs` |
| 3 | Pair / account / fund / deploy account | (direct strkd calls: `companion_requestPairing`, `createAgentAccount`, `requestFunding`, `deployAccount`) |
| 4 | Build + submit DECLARE (canonical ABI, explicit bounds) | `build_declare_bounds.mjs` |
| 5 | Build + submit UDC deploy of `ConfidentialCounter(genesis_root)` | `build_deploy.mjs` |
| 6 | Build + submit `companion_signAndProve` for the virtual `transition` | `build_prove.mjs` |
| 7 | Poll `companion_proveStatus` → `{proof, proof_facts, l2_to_l1_messages}` | `poll_prove.mjs` |
| 8 | **Off-chain pre-check**: recompute the message hash, compare to `proof_facts[8]` | `check_proof.mjs` |
| 9 | Build + submit proof-carrying `apply_transition` (`{proof, proof_facts}`) | `build_txb.mjs` |
| 10 | Wait for Tx B, confirm `get_root()` advanced to `new_root` | `wait_and_root.mjs` |

Step 8 is the safety gate: it catches a wrong `proof_facts` index or message-hash
formula **before** spending a reverting broadcast.

### Utility / diagnostic scripts

Not part of the happy path; kept for debugging and provenance:
`wait.mjs`, `status.mjs` (tx status/finality), `build_declare.mjs` (the initial
submit:true declare), `signonly_declare.mjs`, `recompute_declare_hash.mjs`,
`verify_sig.mjs`, `broadcast_declare.mjs` (used to isolate the ABI/class-hash bug).

## The standalone path (`src/orchestrate.ts`)

Mirrors DESIGN.md's original plan: build the virtual call, set `resourceBounds`
manually, `requestProof` from an SSE proof server (`requestProof.ts`), decode the
L2→L1 message, and `account.execute(verifyCall, { proof, proofFacts })`. It assumes
a **proof-enabled starknet.js fork** (`getSignedTransaction` / `execute` with
`{proof, proofFacts}`), which was not available in this environment — hence the
strkd path was used instead. Treat `orchestrate.ts` as a reference to adapt if you
run your own proof server + fork rather than strkd.

## Config

Copy `orchestration/.env.example` → `.env` and fill RPC URL, account, contract
address, and the (secret) off-chain state. See `orchestration/README.md` for the
standalone-path specifics.
