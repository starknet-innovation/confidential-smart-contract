// Build the UDC deployContract invoke for ConfidentialCounter(genesis_root),
// and compute the deterministic deployed address (unique=0 => deployer 0).
import { hash } from "starknet";
import { readFileSync, writeFileSync } from "node:fs";

const SCRATCH = process.argv[2];
const acct = readFileSync(`${SCRATCH}/strkd_account.txt`, "utf8").trim();
const hashes = JSON.parse(readFileSync(`${SCRATCH}/hashes.json`, "utf8"));
const params = JSON.parse(readFileSync(`${SCRATCH}/params.json`, "utf8"));

const UDC = "0x041a78e741e5af2fec34b695679bc6891742439f7afb8484ecd7766661ad02bf";
const classHash = hashes.class_hash;
const salt = "0x1234abcd";
const unique = "0x0"; // deploy from zero -> deterministic address, deployer = 0
const ctorCalldata = [params.genesis_root];

const address = hash.calculateContractAddressFromHash(salt, classHash, ctorCalldata, 0);

const udcCalldata = [classHash, salt, unique, "0x1", params.genesis_root];
const body = {
  jsonrpc: "2.0", id: 20, method: "wallet_addInvokeTransaction",
  params: {
    account_address: acct,
    calls: [{ contract_address: UDC, entry_point_selector: "deployContract", calldata: udcCalldata }],
    submit: true,
    chainId: "0x534e5f5345504f4c4941",
  },
};
writeFileSync(`${SCRATCH}/deploy_body.json`, JSON.stringify(body));
writeFileSync(`${SCRATCH}/contract_address.txt`, address);
console.log("expected contract address:", address);
console.log("genesis_root            :", params.genesis_root);
