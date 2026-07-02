// Poll companion_proveStatus until the on-device proof job finishes.
import { readFileSync, writeFileSync } from "node:fs";

const SCRATCH = process.argv[2];
const token = readFileSync(`${SCRATCH}/strkd_token.txt`, "utf8").trim();
const job_id = readFileSync(`${SCRATCH}/prove_job.txt`, "utf8").trim();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function status() {
  const r = await fetch("http://127.0.0.1:49163/", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Companion-Client": "claude-code-cc", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ jsonrpc: "2.0", id: 31, method: "companion_proveStatus", params: { job_id } }),
  });
  return (await r.json()).result;
}

let last = "";
for (let i = 0; i < 60; i++) {
  const s = await status();
  if (s.status !== last) { console.error(`[${i * 5}s] status=${s.status}`); last = s.status; }
  if (s.status === "succeeded") {
    writeFileSync(`${SCRATCH}/prove_result.json`, JSON.stringify(s.result, null, 2));
    const r = s.result;
    console.log("SUCCEEDED");
    console.log("proof_facts.len:", r.proof_facts?.length);
    console.log("proof_facts:", JSON.stringify(r.proof_facts));
    console.log("l2_to_l1_messages:", JSON.stringify(r.l2_to_l1_messages));
    console.log("proof bytes (base64 len):", r.proof?.length);
    process.exit(0);
  }
  if (s.status === "failed") {
    console.log("FAILED:", JSON.stringify(s.error));
    process.exit(1);
  }
  await sleep(5000);
}
console.log("timed out polling");
process.exit(2);
