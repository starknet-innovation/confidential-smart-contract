// SNIP-36 orchestration for the confidential counter shard:
//   build virtual tx  ->  prove off-chain  ->  decode message  ->  execute on-chain
//
// ┌─ READ THIS ────────────────────────────────────────────────────────────────┐
// │ The SNIP-36 reference impl orchestrates this flow in RUST and submits via    │
// │ the sequencer GATEWAY (`/gateway/add_transaction`), signing the proof_facts- │
// │ extended tx hash in `crates/snip36-core/src/signing.rs`. The two calls below │
// │ marked `FORK` — `getSignedTransaction` and `execute(call, {proof,proofFacts})│
// │ — are the starknet.js equivalents asserted by the snip-36 skill. A PUBLIC    │
// │ starknet.js fork implementing them was NOT confirmed. If none exists, drive  │
// │ steps 5 & 9 with the Rust `snip36` CLI instead (see orchestration/README).   │
// └──────────────────────────────────────────────────────────────────────────────┘
//
// Server-side ONLY. Private inputs and signing keys must never reach a browser.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { Account, CallData, Contract, RpcProvider, type BigNumberish } from "starknet";
import { requestProof } from "./requestProof.ts";

const __dirname = dirname(fileURLToPath(import.meta.url));

// Compiled ABI from `scarb build`. VERIFY the artifact name matches your package.
const CONTRACT_CLASS = resolve(
  __dirname,
  "../../target/dev/confidential_counter_ConfidentialCounter.contract_class.json",
);
// VERIFY against the ABI: fully-qualified struct path for message decoding.
const PUBLIC_MESSAGE_TYPE = "confidential_counter::interfaces::PublicMessage";

function env(name: string): string {
  const v = process.env[name];
  if (v === undefined || v === "") throw new Error(`missing env var ${name}`);
  return v;
}

async function main() {
  const provider = new RpcProvider({ nodeUrl: env("RPC_URL") });
  const account = new Account({
    provider,
    address: env("ACCOUNT_ADDRESS"),
    signer: env("PRIVATE_KEY"),
  });

  const { abi } = JSON.parse(readFileSync(CONTRACT_CLASS, "utf8"));
  const contract = new Contract(abi, env("CONTRACT_ADDRESS"), account);

  // The confidential pre-state. This is the secret the proof runs over; it lives
  // only here and in the proof server — published NOWHERE.
  const privateInput = { count: env("STATE_COUNT"), salt: env("STATE_SALT") };
  const publicInput = { step: process.env.STEP ?? "1" };

  // 1. Build the VIRTUAL call (never broadcast; its calldata IS the secret state).
  const virtualCall = contract.populate("transition", {
    public_input: publicInput,
    private_input: privateInput,
  });

  // 2. Set resourceBounds MANUALLY. Fee-estimating a virtual tx would ship the
  //    confidential calldata to the RPC node — the one thing we must never do
  //    (SNIP-36 pitfall SNIP36_FEE_ESTIMATION_SENSITIVE). Use ~2x live prices.
  //    VERIFY the max_amount ceilings against a real proof run for your state size.
  const M = 2n;
  const prices = await provider.getGasPrices(); // read-only; carries no calldata
  const resourceBounds = {
    l2_gas: { max_amount: 0x279fc0n * M, max_price_per_unit: BigInt(prices.l2GasPrice) * M },
    l1_gas: { max_amount: 0xbd2an * M, max_price_per_unit: BigInt(prices.l1GasPrice) * M },
    l1_data_gas: { max_amount: 0xc0n * M, max_price_per_unit: BigInt(prices.l1DataGasPrice) * M },
  };

  // 3. Pin the reference block IMMEDIATELY before signing (avoid a stale block).
  const blockNumber = await provider.getBlockNumber();

  // 4. Sign the virtual INVOKE_TXN_V3 without broadcasting.  [FORK]
  const signedTx = await (account as any).getSignedTransaction(virtualCall, { resourceBounds });

  // 5. Prove off-chain (~40-50s, ~18 GB RAM). Returns {proof, proofFacts, msgs}.
  const { proof, proofFacts, l2ToL1Messages } = await requestProof(blockNumber, signedTx);

  // 6. Decode the single L2->L1 message payload back into a PublicMessage. This
  //    is the {old_root, new_root, step} the proof committed to; it must be
  //    passed verbatim so the on-chain proof_facts[8] check matches.
  const payload = l2ToL1Messages?.[0]?.payload as BigNumberish[] | undefined;
  if (!payload) throw new Error("proof result had no L2->L1 message payload");
  const msg = new CallData(abi).decodeParameters(PUBLIC_MESSAGE_TYPE, payload as string[]);
  console.error("[transition]", msg);

  // 7. Submit the ON-CHAIN verify+CAS tx with the proof attached.  [FORK]
  const verifyCall = contract.populate("apply_transition", { msg });
  const { transaction_hash } = await (account as any).execute(verifyCall, { proof, proofFacts });

  await provider.waitForTransaction(transaction_hash);
  console.log(`apply_transition mined: ${transaction_hash}`);
  console.log(`new root: ${await contract.get_root()}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
