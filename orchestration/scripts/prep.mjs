// Off-chain Poseidon params for the test. The salt is the confidential blinding
// factor; here it's a fixed test value. computePoseidonHashOnElements mirrors
// Cairo's poseidon_hash_span (both = poseidonHashMany with standard padding),
// so genesis_root here must equal commit([0, salt]) computed inside the proof.
import { hash } from "starknet";
import { writeFileSync } from "node:fs";

const SALT = "0x1a2b3c4d5e6f7a8b";
const genesis_root = hash.computePoseidonHashOnElements([0n, BigInt(SALT)]);
const new_root_expected = hash.computePoseidonHashOnElements([1n, BigInt(SALT)]);

const out = { salt: SALT, count: "0", step: "1", genesis_root, new_root_expected };
const path = process.argv[2];
if (path) writeFileSync(path, JSON.stringify(out, null, 2));
console.log(JSON.stringify(out, null, 2));
