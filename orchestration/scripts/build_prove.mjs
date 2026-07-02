// Build the companion_signAndProve body for the VIRTUAL transition (Tx A):
//   transition(public_input: Action{step}, private_input: PreState{count, salt})
// calldata = [step, count, salt]. resource_bounds are REQUIRED (never estimate a
// virtual tx). Tx A is never broadcast, so we set generous bounds freely.
import { readFileSync, writeFileSync } from "node:fs";

const SCRATCH = process.argv[2];
const acct = readFileSync(`${SCRATCH}/strkd_account.txt`, "utf8").trim();
const addr = readFileSync(`${SCRATCH}/contract_address.txt`, "utf8").trim();
const params = JSON.parse(readFileSync(`${SCRATCH}/params.json`, "utf8"));
const ctx = JSON.parse(readFileSync(`${SCRATCH}/prove_ctx.json`, "utf8")); // { nonce, block_number }

const calldata = [params.step, params.count, params.salt]; // step, count, salt

// The prover EXECUTES Tx A and enforces balance >= sum(max_amount*max_price),
// even though Tx A is never broadcast. transition() is a tiny invoke, so keep
// bounds modest: l1_gas 0, generous-but-cheap l2/l1_data. Max cost ~2.2 STRK.
const hex = (n) => "0x" + BigInt(n).toString(16);
const resource_bounds = {
  l1_gas: { max_amount: hex(40000), max_price_per_unit: hex(259834885403884n) },
  l2_gas: { max_amount: hex(50000000), max_price_per_unit: hex(43463944681n) },
  l1_data_gas: { max_amount: hex(2000), max_price_per_unit: hex(1457410362673n) },
};

const body = {
  jsonrpc: "2.0", id: 30, method: "companion_signAndProve",
  params: {
    account_address: acct,
    calls: [{ contract_address: addr, entry_point_selector: "transition", calldata }],
    resource_bounds,
    nonce: ctx.nonce,
    block_number: ctx.block_number,
    chainId: "0x534e5f5345504f4c4941",
    label: "cc-transition",
  },
};
writeFileSync(`${SCRATCH}/prove_body.json`, JSON.stringify(body));
console.log("calls[0].calldata (step,count,salt):", calldata.join(", "));
console.log("contract:", addr);
