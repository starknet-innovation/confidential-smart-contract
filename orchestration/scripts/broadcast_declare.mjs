// Broadcast the strkd-signed (sign-only) DECLARE v3 ourselves. strkd's echoed
// signed_transaction omits the fee fields, so we reassemble the full tx from the
// exact fields we signed over (proven canonical: our hash == strkd's hash) plus
// the signature strkd returned. Keyless: the signature authorizes it.
import { json } from "starknet";
import { readFileSync } from "node:fs";

const SCRATCH = process.argv[2];
const RPC = "https://api.cartridge.gg/x/starknet/sepolia";
const acct = readFileSync(`${SCRATCH}/strkd_account.txt`, "utf8").trim();
const hashes = JSON.parse(readFileSync(`${SCRATCH}/hashes.json`, "utf8"));
const resp = JSON.parse(readFileSync(`${SCRATCH}/declare_signonly_resp.json`, "utf8"));
const signature = resp.result.signature;

const raw = json.parse(
  readFileSync("../target/dev/confidential_counter_ConfidentialCounter.contract_class.json", "utf8"),
);
const contract_class = {
  sierra_program: raw.sierra_program,
  contract_class_version: raw.contract_class_version,
  entry_points_by_type: raw.entry_points_by_type,
  abi: JSON.stringify(raw.abi),
};

const hex = (n) => "0x" + BigInt(n).toString(16);
const declare_tx = {
  type: "DECLARE",
  version: "0x3",
  sender_address: acct,
  compiled_class_hash: hashes.compiled_class_hash,
  nonce: "0x1",
  signature,
  resource_bounds: {
    l1_gas: { max_amount: hex(0), max_price_per_unit: hex(259834885403884n * 2n) },
    l2_gas: { max_amount: hex(130848432n * 2n), max_price_per_unit: hex(43463944681n * 2n) },
    l1_data_gas: { max_amount: hex(288n * 2n), max_price_per_unit: hex(1457410362673n * 2n) },
  },
  tip: "0x0",
  paymaster_data: [],
  account_deployment_data: [],
  nonce_data_availability_mode: "L1",
  fee_data_availability_mode: "L1",
  contract_class,
};

const body = { jsonrpc: "2.0", id: 1, method: "starknet_addDeclareTransaction", params: [declare_tx] };
const r = await (await fetch(RPC, {
  method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
})).json();
console.log(JSON.stringify(r, null, 2));
