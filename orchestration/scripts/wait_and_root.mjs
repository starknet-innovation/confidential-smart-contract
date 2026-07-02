// Poll Tx B to finality, then read get_root and compare to the expected new_root.
import { hash } from "starknet";
import { readFileSync } from "node:fs";

const SCRATCH = process.argv[2];
const RPC = "https://api.cartridge.gg/x/starknet/sepolia";
const txh = readFileSync(`${SCRATCH}/txb_txh.txt`, "utf8").trim();
const addr = readFileSync(`${SCRATCH}/contract_address.txt`, "utf8").trim();
const params = JSON.parse(readFileSync(`${SCRATCH}/params.json`, "utf8"));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rpc = (method, prms) => fetch(RPC, {
  method: "POST", headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params: prms }),
}).then((r) => r.json());

let fin, exec, reason;
for (let i = 0; i < 40; i++) {
  const s = (await rpc("starknet_getTransactionStatus", [txh])).result;
  if (s) {
    fin = s.finality_status; exec = s.execution_status; reason = s.failure_reason;
    if (fin && fin !== "RECEIVED") break;
  }
  await sleep(6000);
}
console.log(`Tx B: finality=${fin} execution=${exec}`);
if (reason) console.log("failure_reason:", JSON.stringify(reason));
if (exec === "REVERTED") {
  const rc = (await rpc("starknet_getTransactionReceipt", [txh])).result;
  console.log("revert_reason:", rc?.revert_reason ?? "(none)");
  process.exit(1);
}

const sel = hash.getSelectorFromName("get_root");
const root = (await rpc("starknet_call", [{ contract_address: addr, entry_point_selector: sel, calldata: [] }, "latest"])).result;
console.log("get_root()        :", root?.[0]);
console.log("expected new_root :", params.new_root_expected);
const eq = BigInt(root[0]) === BigInt(params.new_root_expected);
console.log("ROOT ADVANCED TO new_root:", eq);
process.exit(eq ? 0 : 1);
