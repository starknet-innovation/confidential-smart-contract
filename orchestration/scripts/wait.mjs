// Poll a Sepolia tx to finality using a PUBLIC read RPC (the wallet's node is
// not exposed for arbitrary reads). Read-only; carries no secrets.
import { RpcProvider } from "starknet";

const RPC = process.env.RPC || "https://rpc.starknet-testnet.lava.build";
const txh = process.argv[2];
if (!txh) { console.error("usage: wait.mjs <tx_hash>"); process.exit(2); }

const provider = new RpcProvider({ nodeUrl: RPC });
try {
  const r = await provider.waitForTransaction(txh, { retryInterval: 4000 });
  const exec = r.execution_status ?? r.value?.execution_status ?? "?";
  const fin = r.finality_status ?? r.value?.finality_status ?? "?";
  console.log(`finality=${fin} execution=${exec}`);
  if (exec === "REVERTED") { console.log("revert_reason:", r.revert_reason ?? "(none)"); process.exit(1); }
} catch (e) {
  console.error("wait error:", e?.message ?? String(e));
  process.exit(1);
}
