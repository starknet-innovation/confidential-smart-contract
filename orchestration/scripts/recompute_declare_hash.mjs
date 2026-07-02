// Independently recompute the DECLARE v3 tx hash with starknet.js, using the
// exact fields handed to strkd, and compare against strkd's returned hash.
import { hash, ec } from "starknet";
import { readFileSync } from "node:fs";

const SCRATCH = process.argv[2];
const hashes = JSON.parse(readFileSync(`${SCRATCH}/hashes.json`, "utf8"));
const acct = readFileSync(`${SCRATCH}/strkd_account.txt`, "utf8").trim();
const resp = JSON.parse(readFileSync(`${SCRATCH}/declare_signonly_resp.json`, "utf8"));
const strkdHash = resp.result?.transaction_hash;
const sig = resp.result?.signature;

// resourceBounds values MUST be BigInt (they are bit-shifted in encoding).
const resourceBounds = {
  l1_gas: { max_amount: 0n, max_price_per_unit: 259834885403884n * 2n },
  l2_gas: { max_amount: 130848432n * 2n, max_price_per_unit: 43463944681n * 2n },
  l1_data_gas: { max_amount: 288n * 2n, max_price_per_unit: 1457410362673n * 2n },
};

const args = {
  classHash: hashes.class_hash,
  compiledClassHash: hashes.compiled_class_hash,
  senderAddress: acct,
  version: "0x3",
  chainId: "0x534e5f5345504f4c4941",
  nonce: "0x1",
  accountDeploymentData: [],
  nonceDataAvailabilityMode: 0,
  feeDataAvailabilityMode: 0,
  resourceBounds,
  tip: 0,
  paymasterData: [],
};

const mine = hash.calculateDeclareTransactionHash(args);

console.log("strkd  hash:", strkdHash);
console.log("mine   hash:", mine);
console.log("MATCH:", BigInt(mine) === BigInt(strkdHash));

// Get the account's public key on-chain, verify the signature over each hash.
const RPC = "https://api.cartridge.gg/x/starknet/sepolia";
async function getPubKey() {
  for (const sel of ["get_public_key", "getPublicKey"]) {
    const body = { jsonrpc: "2.0", id: 1, method: "starknet_call",
      params: [{ contract_address: acct, entry_point_selector: hash.getSelectorFromName(sel), calldata: [] }, "latest"] };
    const r = await (await fetch(RPC, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) })).json();
    if (r.result?.[0]) return r.result[0];
  }
  return null;
}
const pub = await getPubKey();
console.log("account pubkey:", pub);
if (pub && sig?.length === 2) {
  const sigObj = { r: BigInt(sig[0]), s: BigInt(sig[1]) };
  const okMine = ec.starkCurve.verify(sigObj, BigInt(mine).toString(16), BigInt(pub).toString(16));
  const okStrkd = ec.starkCurve.verify(sigObj, BigInt(strkdHash).toString(16), BigInt(pub).toString(16));
  console.log("signature valid over MINE  hash:", okMine);
  console.log("signature valid over STRKD hash:", okStrkd);
}
