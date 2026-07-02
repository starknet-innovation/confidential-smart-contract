// Compute class_hash (Sierra) and compiled_class_hash (CASM) from the scarb build.
import { hash, json } from "starknet";
import { readFileSync } from "node:fs";
import { writeFileSync } from "node:fs";

const dir = "../target/dev";
const sierra = json.parse(readFileSync(`${dir}/confidential_counter_ConfidentialCounter.contract_class.json`, "utf8"));
const casm = json.parse(readFileSync(`${dir}/confidential_counter_ConfidentialCounter.compiled_contract_class.json`, "utf8"));

const class_hash = hash.computeContractClassHash(sierra);
const compiled_class_hash = hash.computeCompiledClassHash(casm);

const out = { class_hash, compiled_class_hash };
const path = process.argv[2];
if (path) writeFileSync(path, JSON.stringify(out, null, 2));
console.log(JSON.stringify(out, null, 2));
