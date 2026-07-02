// Build a submit:true DECLARE body with EXPLICIT resource_bounds + nonce, so
// strkd skips its (buggy) auto-estimate path. Broadcast still goes through
// strkd (human-approved). Written to a file for `curl --data @`.
import { json } from "starknet";
import { readFileSync, writeFileSync } from "node:fs";

// starknet.js's canonical ABI stringify (formatSpaces): a space after ':' and
// ',' outside quotes. The node re-derives the class hash from the ABI STRING we
// send; a non-canonical (compact) string yields a different class hash than the
// one strkd signs, surfacing as 'Account: invalid signature'.
function formatSpaces(s) {
  let q = false;
  const out = [];
  for (const c of s) {
    if (c === '"' && !(out.length > 0 && out[out.length - 1] === "\\")) q = !q;
    out.push(q ? c : c === ":" ? ": " : c === "," ? ", " : c);
  }
  return out.join("");
}

const [, , acct, hashesPath, outPath] = process.argv;
const hashes = JSON.parse(readFileSync(hashesPath, "utf8"));
const raw = json.parse(
  readFileSync("../target/dev/confidential_counter_ConfidentialCounter.contract_class.json", "utf8"),
);
const contract_class = {
  sierra_program: raw.sierra_program,
  contract_class_version: raw.contract_class_version,
  entry_points_by_type: raw.entry_points_by_type,
  abi: formatSpaces(json.stringify(raw.abi)),
};

const hex = (n) => "0x" + BigInt(n).toString(16);
const body = {
  jsonrpc: "2.0", id: 12, method: "wallet_addDeclareTransaction",
  params: {
    account_address: acct,
    class_hash: hashes.class_hash,
    compiled_class_hash: hashes.compiled_class_hash,
    contract_class,
    nonce: "0x1",
    // Node's estimate: amounts ×2 for execution headroom, prices ×1 (the
    // estimate already carries price margin). Max cost ~11.4 STRK < balance.
    resource_bounds: {
      l1_gas: { max_amount: hex(0), max_price_per_unit: hex(259834885403884n) },
      l2_gas: { max_amount: hex(130848432n * 2n), max_price_per_unit: hex(43463944681n) },
      l1_data_gas: { max_amount: hex(288n * 2n), max_price_per_unit: hex(1457410362673n) },
    },
    submit: true,
    chainId: "0x534e5f5345504f4c4941",
  },
};
writeFileSync(outPath, JSON.stringify(body));
console.log("declare(submit+bounds) body bytes:", JSON.stringify(body).length);
