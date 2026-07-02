// Build Tx B: the proof-carrying apply_transition(msg) broadcast.
// calldata = serialize(PublicMessage) = [old_root, new_root, step] = the message
// payload. proof_facts extend the signed hash; proof rides along on submit.
// resource_bounds are REQUIRED for proof-carrying invokes (no estimation).
import { readFileSync, writeFileSync } from "node:fs";

const SCRATCH = process.argv[2];
const acct = readFileSync(`${SCRATCH}/strkd_account.txt`, "utf8").trim();
const addr = readFileSync(`${SCRATCH}/contract_address.txt`, "utf8").trim();
const r = JSON.parse(readFileSync(`${SCRATCH}/prove_result.json`, "utf8"));
const payload = r.l2_to_l1_messages[0].payload; // [old_root, new_root, step]

const hex = (n) => "0x" + BigInt(n).toString(16);
// real block prices ×2 for margin; amounts sized for the ~238KB proof + exec.
const resource_bounds = {
  l1_gas: { max_amount: hex(10000), max_price_per_unit: hex(113199090239245n * 2n) },
  l2_gas: { max_amount: hex(120000000), max_price_per_unit: hex(28585350008n * 2n) },
  l1_data_gas: { max_amount: hex(10000), max_price_per_unit: hex(485785311247n * 2n) },
};

const body = {
  jsonrpc: "2.0", id: 50, method: "wallet_addInvokeTransaction",
  params: {
    account_address: acct,
    calls: [{ contract_address: addr, entry_point_selector: "apply_transition", calldata: payload }],
    proof_facts: r.proof_facts,
    proof: r.proof,
    resource_bounds,
    submit: true,
    chainId: "0x534e5f5345504f4c4941",
  },
};
writeFileSync(`${SCRATCH}/txb_body.json`, JSON.stringify(body));
console.log("apply_transition calldata:", payload.join(", "));
console.log("proof_facts:", r.proof_facts.length, "felts; proof b64 len:", r.proof.length);
