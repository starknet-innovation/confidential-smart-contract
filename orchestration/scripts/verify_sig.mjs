// Confirm strkd's SIGN-ONLY declare signature is cryptographically valid over
// the canonical DECLARE v3 hash, under the account's on-chain public key.
import { hash, ec } from "starknet";
import { readFileSync } from "node:fs";

const SCRATCH = process.argv[2];
const hashes = JSON.parse(readFileSync(`${SCRATCH}/hashes.json`, "utf8"));
const acct = readFileSync(`${SCRATCH}/strkd_account.txt`, "utf8").trim();
const resp = JSON.parse(readFileSync(`${SCRATCH}/declare_signonly_resp.json`, "utf8"));
const sig = resp.result.signature;
const strkdHash = resp.result.transaction_hash;
const pub = "0x30b9b0b148da7b790ebeaf573d06668ebde42c6543347651cb5f55962d296d3";

// Same bounds used in the sign-only request (×2 on both amount and price).
const resourceBounds = {
  l1_gas: { max_amount: 0n, max_price_per_unit: 259834885403884n * 2n },
  l2_gas: { max_amount: 130848432n * 2n, max_price_per_unit: 43463944681n * 2n },
  l1_data_gas: { max_amount: 288n * 2n, max_price_per_unit: 1457410362673n * 2n },
};
const mine = hash.calculateDeclareTransactionHash({
  classHash: hashes.class_hash, compiledClassHash: hashes.compiled_class_hash,
  senderAddress: acct, version: "0x3", chainId: "0x534e5f5345504f4c4941", nonce: "0x1",
  accountDeploymentData: [], nonceDataAvailabilityMode: 0, feeDataAvailabilityMode: 0,
  resourceBounds, tip: 0, paymasterData: [],
});

const rHex = BigInt(sig[0]).toString(16).padStart(64, "0");
const sHex = BigInt(sig[1]).toString(16).padStart(64, "0");
const sigHex = rHex + sHex;
const msgHex = BigInt(mine).toString(16).padStart(64, "0");
const pubHex = BigInt(pub).toString(16).padStart(64, "0");

console.log("canonical hash == strkd hash:", BigInt(mine) === BigInt(strkdHash));
console.log("sign-only signature valid over canonical hash:", ec.starkCurve.verify(sigHex, msgHex, pubHex));
