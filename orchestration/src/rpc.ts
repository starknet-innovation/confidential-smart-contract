// Minimal read-only Starknet RPC helpers (public node). Read-only; carries no secrets.
// Used for status/nonce/balance queries and class-hash computation during orchestration.

import { hash, json } from "starknet";
import { readFileSync } from "node:fs";

const RPC = process.env.READ_RPC_URL ?? "https://api.cartridge.gg/x/starknet/sepolia";

async function call(method: string, params: unknown): Promise<any> {
  const res = await fetch(RPC, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const j: any = await res.json();
  if (j.error) throw Object.assign(new Error(j.error.message), { code: j.error.code });
  return j.result;
}

export const getNonce = (addr: string) => call("starknet_getNonce", ["latest", addr]);
export const getBlockNumber = () => call("starknet_blockNumber", []);
export const getTxStatus = (txh: string) => call("starknet_getTransactionStatus", [txh]);

export async function contractCall(address: string, entrypoint: string, calldata: string[] = []) {
  return call("starknet_call", [
    { contract_address: address, entry_point_selector: hash.getSelectorFromName(entrypoint), calldata },
    "latest",
  ]);
}

export async function waitForTx(txh: string, tries = 60, intervalMs = 5000): Promise<string> {
  for (let i = 0; i < tries; i++) {
    try {
      const s = await getTxStatus(txh);
      const fin = s.finality_status, exec = s.execution_status;
      if (fin && fin !== "RECEIVED") {
        if (exec === "REVERTED") throw new Error(`tx reverted: ${JSON.stringify(s.failure_reason ?? s)}`);
        return `${fin}/${exec ?? "?"}`;
      }
    } catch (e: any) {
      if (String(e?.message).includes("reverted")) throw e; // real revert
      // else: not found yet; keep polling
    }
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error(`waitForTx timed out for ${txh}`);
}

/** Compute the Sierra class hash from a scarb-built .contract_class.json. */
export function classHashOf(artifactPath: string): bigint {
  const sierra = json.parse(readFileSync(artifactPath, "utf8"));
  return BigInt(hash.computeContractClassHash(sierra));
}

/** Produce the RPC-ready contract_class (canonical spaced ABI string; drop debug info). */
export function rpcContractClass(artifactPath: string): any {
  const raw = json.parse(readFileSync(artifactPath, "utf8"));
  return {
    sierra_program: raw.sierra_program,
    contract_class_version: raw.contract_class_version,
    entry_points_by_type: raw.entry_points_by_type,
    abi: Array.isArray(raw.abi) ? formatSpaces(json.stringify(raw.abi)) : raw.abi,
  };
}

// starknet.js's canonical ABI stringify: a space after ':' and ',' outside quotes.
// The node re-derives the class hash from this string; a compact string diverges and
// surfaces as a misleading 'Account: invalid signature' on declare.
function formatSpaces(s: string): string {
  let q = false;
  const out: string[] = [];
  for (const c of s) {
    if (c === '"' && out[out.length - 1] !== "\\") q = !q;
    out.push(q ? c : c === ":" ? ": " : c === "," ? ", " : c);
  }
  return out.join("");
}
