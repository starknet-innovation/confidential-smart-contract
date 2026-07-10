// End-to-end demo of the SDK: deploy a counter shard and drive two transitions.
//
// This file is intentionally small — that is the point of the SDK. All the framework
// mechanics (encodings, salt rotation, proof pre-check, apply, consume) live behind
// `deployShard` / `shard.transition`; here we just pick a logic and act.
//
// Server-side only. Requires a running strkd companion (STRKD_URL, STRKD_TOKEN) with a
// funded + deployed account, the framework + logic classes already DECLARED, and a
// configured prover. Every sensitive step prompts the human. On-chain steps only run when
// RUN_ONCHAIN=1 is set — otherwise it prints the genesis/address it would use.

import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { genesisOf, hex, deployShard } from "./index.ts";
import { counterLogic } from "./apps/counter.ts";
import { StrkdBackend } from "./strkd-backend.ts";
import { Strkd } from "./strkd.ts";
import * as rpc from "./rpc.ts";

const __dirname = dirname(fileURLToPath(import.meta.url));
const artifact = (name: string) => resolve(__dirname, `../../target/dev/confidential_counter_${name}.contract_class.json`);
const env = (k: string) => { const v = process.env[k]; if (!v) throw new Error(`missing env ${k}`); return v; };

async function main() {
  // Class hashes come from the scarb build (declaring them is a prerequisite — the prover
  // library_calls the logic class).
  const frameworkClassHash = rpc.classHashOf(artifact("ConfidentialShard"));
  const logicClassHash = rpc.classHashOf(artifact("CounterLogic"));

  // 1. Pick a logic (the counter — a transparent, opt-out example: no blinding). 2. Genesis.
  const logic = counterLogic(logicClassHash);
  const { state: genesisState, root: genesisRoot } = genesisOf(logic, { count: 0n });

  console.error(`app=${logic.name} framework=${hex(frameworkClassHash)} logic=${hex(logicClassHash)}`);
  console.error(`genesis: ${logic.describe(logic.decodeState(genesisState.appState))} -> root ${hex(genesisRoot)}`);

  if (process.env.RUN_ONCHAIN !== "1") {
    console.error(`\n[dry run] set RUN_ONCHAIN=1 (and STRKD_URL/STRKD_TOKEN/ACCOUNT_ADDRESS/DEPLOY_SALT) to deploy + transition.`);
    return;
  }

  // 3. A backend (strkd reference impl). 4. Deploy + drive transitions.
  const backend = new StrkdBackend(new Strkd(env("STRKD_URL"), env("STRKD_TOKEN")), env("ACCOUNT_ADDRESS"));
  const { shard, address } = await deployShard({
    backend, frameworkClassHash, logic,
    initial: { count: 0n }, deploySalt: BigInt(env("DEPLOY_SALT")),
  });
  console.error(`deployed shard at ${hex(address)}`);

  for (const step of [1n, 1n]) {
    const r = await shard.transition({ step });
    console.error(`transition step=${step} -> ${logic.describe(shard.state)} root=${hex(r.root)} actions=${r.actions}`);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) main().catch((e) => { console.error(e); process.exit(1); });
