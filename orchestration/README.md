# Orchestration — SNIP-36 prove → decode → execute

Drives one confidential counter transition end-to-end:

```
build virtual tx  ─▶  prove off-chain  ─▶  decode L2→L1 msg  ─▶  execute on-chain (verify + CAS)
   (secret state)      (~40-50s, 18GB)      {old,new,step}         {proof, proofFacts}
```

## Run

```bash
cp .env.example .env      # fill in RPC, account, contract, and the SECRET state
npm install
# a SNIP-36 proof server (Rust snip36 backend + SSE /prove) must be reachable at PROOF_SERVER_URL
npm run transition
```

Requires Node 22+ (`--experimental-strip-types` runs the `.ts` files directly).

## Non-negotiables

- **Never fee-estimate the virtual tx.** Estimation ships the calldata — which *is*
  the confidential state — to the RPC node. `orchestrate.ts` sets `resourceBounds`
  manually at ~2× live gas prices instead. (`getGasPrices()` is read-only and carries
  no calldata.)
- **Server-side only.** Private inputs and the signing key must never reach a browser.
- **Pin `blockNumber` right before signing** to avoid a stale reference block.

## ⚠️ VERIFY before trusting this against a live network

The SNIP-36 reference implementation
([snip-36-prover-backend](https://github.com/starknet-innovation/snip-36-prover-backend))
orchestrates this flow **in Rust** and submits via the sequencer **gateway**
(`/gateway/add_transaction`), signing the `proof_facts`-extended tx hash in
`crates/snip36-core/src/signing.rs`. It does **not** ship a starknet.js path.

So two things here are asserted by the `snip-36` skill but **unconfirmed** against
that reference:

1. `account.getSignedTransaction(call, { resourceBounds })` — signing a virtual tx
   without broadcasting.
2. `account.execute(call, { proof, proofFacts })` — appending `proof_facts_hash` to
   the v3 tx hash on submit.

Both are marked `[FORK]` in `orchestrate.ts` and cast through `as any` because stock
starknet.js types don't include them. **If a proof-enabled starknet.js fork is not
available, drive steps 4–5 and 7 with the Rust `snip36` CLI** (`snip36 prove
virtual-os …`) and gateway submission, exactly as the reference does. Confirm which
path exists before wiring this into anything real.

Other `VERIFY` markers in the code:

- `PUBLIC_MESSAGE_TYPE` — confirm the fully-qualified struct path against the built ABI.
- `resourceBounds.max_amount` ceilings — tune against a real proof run for your state size.
- The `--tx-json` vs `--tx-hash` CLI flag (the reference e2e used `--tx-hash`).
