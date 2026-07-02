// Assemble the wallet_addDeclareTransaction JSON-RPC body (embeds the Sierra
// contract_class, needed for submit:true). Written to a file for `curl --data @`.
import { json } from "starknet";
import { readFileSync, writeFileSync } from "node:fs";

const [, , acct, hashesPath, outPath] = process.argv;
const hashes = JSON.parse(readFileSync(hashesPath, "utf8"));
const raw = json.parse(
  readFileSync("../target/dev/confidential_counter_ConfidentialCounter.contract_class.json", "utf8"),
);
// The RPC SierraClass accepts ONLY these fields; scarb also emits
// `sierra_program_debug_info`, which the strict declare endpoint rejects.
// `abi` must be a JSON string (scarb emits an array).
const sierra = {
  sierra_program: raw.sierra_program,
  contract_class_version: raw.contract_class_version,
  entry_points_by_type: raw.entry_points_by_type,
  abi: Array.isArray(raw.abi) ? JSON.stringify(raw.abi) : raw.abi,
};

const body = {
  jsonrpc: "2.0",
  id: 10,
  method: "wallet_addDeclareTransaction",
  params: {
    account_address: acct,
    class_hash: hashes.class_hash,
    compiled_class_hash: hashes.compiled_class_hash,
    contract_class: sierra,
    submit: true,
    chainId: "0x534e5f5345504f4c4941",
  },
};
writeFileSync(outPath, JSON.stringify(body));
console.log("declare body bytes:", JSON.stringify(body).length);
