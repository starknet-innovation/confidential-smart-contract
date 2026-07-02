// Diagnostic: sign-only DECLARE via strkd, then dump the response so we can
// independently recompute the v3 declare hash and locate the invalid-signature.
import { json } from "starknet";
import { readFileSync, writeFileSync } from "node:fs";

const SCRATCH = process.argv[2];
const token = readFileSync(`${SCRATCH}/strkd_token.txt`, "utf8").trim();
const acct = readFileSync(`${SCRATCH}/strkd_account.txt`, "utf8").trim();
const hashes = JSON.parse(readFileSync(`${SCRATCH}/hashes.json`, "utf8"));

const raw = json.parse(
  readFileSync("../target/dev/confidential_counter_ConfidentialCounter.contract_class.json", "utf8"),
);
const contract_class = {
  sierra_program: raw.sierra_program,
  contract_class_version: raw.contract_class_version,
  entry_points_by_type: raw.entry_points_by_type,
  abi: Array.isArray(raw.abi) ? JSON.stringify(raw.abi) : raw.abi,
};

const hex = (n) => "0x" + BigInt(n).toString(16);
// Node's earlier estimate, ×2 for headroom.
const resource_bounds = {
  l1_gas: { max_amount: hex(0), max_price_per_unit: hex(259834885403884n * 2n) },
  l2_gas: { max_amount: hex(130848432n * 2n), max_price_per_unit: hex(43463944681n * 2n) },
  l1_data_gas: { max_amount: hex(288n * 2n), max_price_per_unit: hex(1457410362673n * 2n) },
};

const body = {
  jsonrpc: "2.0", id: 11, method: "wallet_addDeclareTransaction",
  params: {
    account_address: acct,
    class_hash: hashes.class_hash,
    compiled_class_hash: hashes.compiled_class_hash,
    contract_class,
    nonce: "0x1",
    resource_bounds,
    submit: false,
    chainId: "0x534e5f5345504f4c4941",
  },
};

const res = await fetch("http://127.0.0.1:49163/", {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "X-Companion-Client": "claude-code-cc",
    "Authorization": `Bearer ${token}`,
  },
  body: JSON.stringify(body),
});
const out = await res.json();
writeFileSync(`${SCRATCH}/declare_signonly_resp.json`, JSON.stringify(out, null, 2));
// Print a compact view (signed_transaction can be huge).
const r = out.result ?? out.error ?? out;
const brief = out.error ? out : {
  transaction_hash: r.transaction_hash,
  signature: r.signature,
  signed_tx_keys: r.signed_transaction ? Object.keys(r.signed_transaction) : null,
  signed_tx_no_class: r.signed_transaction
    ? { ...r.signed_transaction, contract_class: r.signed_transaction.contract_class ? "<omitted>" : undefined }
    : null,
};
console.log(JSON.stringify(brief, null, 2));
