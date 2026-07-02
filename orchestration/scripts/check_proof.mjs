// Off-chain pre-check: reproduce the on-chain compute_message_hash and compare
// to proof_facts[8], BEFORE broadcasting Tx B. Also sanity-check the message.
import { hash } from "starknet";
import { readFileSync } from "node:fs";

const SCRATCH = process.argv[2];
const r = JSON.parse(readFileSync(`${SCRATCH}/prove_result.json`, "utf8"));
const addr = readFileSync(`${SCRATCH}/contract_address.txt`, "utf8").trim();
const params = JSON.parse(readFileSync(`${SCRATCH}/params.json`, "utf8"));

const pf = r.proof_facts;
const msg = r.l2_to_l1_messages[0];
const payload = msg.payload; // [old_root, new_root, step]

// Mirror Cairo compute_message_hash: poseidon([from, to, payload_len, ...payload]).
const data = [addr, msg.to_address, "0x" + payload.length.toString(16), ...payload];
const myHash = hash.computePoseidonHashOnElements(data);

const eq = (a, b) => BigInt(a) === BigInt(b);
console.log("proof_facts[7] (n_msgs) == 1 :", eq(pf[7], 1n));
console.log("proof_facts[8]              :", pf[8]);
console.log("my compute_message_hash     :", myHash);
console.log("MESSAGE-HASH MATCH          :", eq(myHash, pf[8]));
console.log("old_root == deployed genesis:", eq(payload[0], params.genesis_root));
console.log("new_root == poseidon([1,s]) :", eq(payload[1], params.new_root_expected));
console.log("step == 1                   :", eq(payload[2], 1n));
