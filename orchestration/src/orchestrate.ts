// Generic end-to-end driver for the confidential shard framework, via the strkd
// wallet companion. It is parameterized by an `Example` (see ./examples/counter.ts),
// so the counter is just one thing you can pass in — swap in any Example to drive a
// different application through the same framework.
//
// Flow: declare framework + logic -> deploy framework(genesis_root) -> for each action:
//   build virtual transition -> sign+prove (Tx A) -> off-chain pre-check -> broadcast
//   apply_transition with {proof, proofFacts} (Tx B) -> verify root advanced.
//
// Server-side only. Requires a running strkd companion (STRKD_URL, STRKD_TOKEN) with a
// funded+deployed account, and a configured prover. Every sensitive step prompts the human.

import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { hash as snhash } from "starknet";
import * as fw from "./framework.ts";
import { Strkd, hex, type ResourceBounds, type Call } from "./strkd.ts";
import * as rpc from "./rpc.ts";
import { counterExample } from "./examples/counter.ts";
import type { Example } from "./examples/types.ts";

const __dirname = dirname(fileURLToPath(import.meta.url));
const artifact = (name: string) => resolve(__dirname, `../../target/dev/confidential_counter_${name}.contract_class.json`);
const UDC = "0x041a78e741e5af2fec34b695679bc6891742439f7afb8484ecd7766661ad02bf";

const env = (k: string) => { const v = process.env[k]; if (!v) throw new Error(`missing env ${k}`); return v; };

// Generous manual bounds (~2x). Tune per real proof size; the prover enforces the
// account balance against these. NEVER fee-estimate a virtual/proof-carrying tx.
async function bounds(kind: "prove" | "apply"): Promise<ResourceBounds> {
  const l2Amount = kind === "apply" ? 120_000_000n : 50_000_000n; // proof-carrying tx needs more L2 gas
  return {
    l1_gas: { max_amount: hex(60_000n), max_price_per_unit: hex(300_000_000_000_000n) },
    l2_gas: { max_amount: hex(l2Amount), max_price_per_unit: hex(90_000_000_000n) },
    l1_data_gas: { max_amount: hex(20_000n), max_price_per_unit: hex(2_000_000_000_000n) },
  };
}

/** UDC deployContract(class_hash, salt, unique=0, [genesis_root]) -> deterministic address. */
function deployCall(frameworkClassHash: bigint, salt: bigint, genesisRoot: bigint): { call: Call; address: bigint } {
  const chHex = hex(frameworkClassHash), saltHex = hex(salt), rootHex = hex(genesisRoot);
  const address = BigInt(snhash.calculateContractAddressFromHash(saltHex, chHex, [rootHex], 0));
  const call: Call = { contract_address: UDC, entry_point_selector: "deployContract", calldata: [chHex, saltHex, "0x0", "0x1", rootHex] };
  return { call, address };
}

/** Run one transition (action) against a deployed shard, returning the new root. */
export async function runTransition(opts: {
  strkd: Strkd; account: string; contract: bigint; example: Example; action: unknown;
  state: fw.ShardState; // the current confidential state (secret-holder's knowledge)
}): Promise<{ newState: fw.ShardState; newRoot: bigint }> {
  const { strkd, account, contract, example, action, state } = opts;
  const publicInput = example.buildPublicInput(action);

  // Fresh blinding for the successor state (per-transition salt rotation), plus the
  // off-chain mirror of the next state so we can pre-check the proof's new_root.
  const newSalt = fw.freshSalt();
  const expectedNext = example.nextState(state, action, newSalt);
  const expectedNewRoot = fw.commit(expectedNext);

  const oldRoot = fw.commit(state);
  const nonce = await rpc.getNonce(account);
  const blockNumber = Number(await rpc.getBlockNumber()) - 2;

  // Tx A: sign + prove the virtual transition. calldata = (public_input, state, new_salt).
  const call: Call = { contract_address: hex(contract), entry_point_selector: "transition", calldata: fw.transitionCalldata(publicInput, state, newSalt) };
  const { job_id } = await strkd.signAndProve({ account, calls: [call], resourceBounds: await bounds("prove"), nonce, blockNumber, label: example.name });
  const proof = await strkd.waitProof(job_id);

  // Decode the proven message and PRE-CHECK it before broadcasting (no wasted revert).
  const msg = fw.decodePublicMessage(proof.l2_to_l1_messages[0].payload);
  const check = fw.checkProof({ proofFacts: proof.proof_facts, l2Payload: proof.l2_to_l1_messages[0].payload, contractAddress: contract, expectedOldRoot: oldRoot, expectedNewRoot });
  if (!check.ok) throw new Error(`pre-check failed: ${check.reasons.join("; ")}`);

  // Tx B: broadcast apply_transition with the proof attached.
  const applyCall: Call = { contract_address: hex(contract), entry_point_selector: "apply_transition", calldata: fw.applyTransitionCalldata(msg) };
  const { transaction_hash } = await strkd.addInvoke({ account, calls: [applyCall], resourceBounds: await bounds("apply"), proof: proof.proof, proofFacts: proof.proof_facts });
  await rpc.waitForTx(transaction_hash);

  const onchain = BigInt((await rpc.contractCall(hex(contract), "get_root"))[0]);
  if (onchain !== msg.newRoot) throw new Error(`root mismatch after apply: ${hex(onchain)} != ${hex(msg.newRoot)}`);

  // Advance local state to the mirror we already computed (successor logic hash +
  // new app_state + rotated salt).
  return { newState: expectedNext, newRoot: msg.newRoot };
}

async function main() {
  const strkd = new Strkd(env("STRKD_URL"), env("STRKD_TOKEN"));
  const account = env("ACCOUNT_ADDRESS");
  const salt = BigInt(env("SALT"));

  // The counter is just one example plugged into the generic framework.
  const logicClassHash = rpc.classHashOf(artifact("CounterLogic"));
  const frameworkClassHash = rpc.classHashOf(artifact("ConfidentialShard"));
  const example = counterExample(logicClassHash, 0n);

  // Genesis: commit the initial state (incl. the logic class hash) OFF-CHAIN.
  const genesisState = example.genesisState(salt);
  const genesisRoot = fw.commit(genesisState);
  const { address } = deployCall(frameworkClassHash, BigInt(env("DEPLOY_SALT")), genesisRoot);

  console.error(`example=${example.name} framework=${hex(frameworkClassHash)} logic=${hex(logicClassHash)}`);
  console.error(`genesis: ${example.describe(genesisState)} -> root ${hex(genesisRoot)}`);
  console.error(`shard address (once deployed): ${hex(address)}`);
  console.error(`\nDeclare framework+logic and deploy the shard via strkd, then call runTransition(...) per action.`);
  console.error(`(Declaring the logic class is a prerequisite — the prover library_calls it.)`);
  // Deploy + declare + transition wiring is intentionally left to the operator to drive
  // step-by-step (each strkd call prompts). runTransition() above is the reusable core.
}

if (import.meta.url === `file://${process.argv[1]}`) main().catch((e) => { console.error(e); process.exit(1); });
