import { RpcProvider } from "starknet";
const RPC = process.env.RPC;
const txh = process.argv[2];
const p = new RpcProvider({ nodeUrl: RPC });
try {
  const s = await p.getTransactionStatus(txh);
  console.log(`OK ${RPC} ->`, JSON.stringify(s));
} catch (e) {
  console.log(`ERR ${RPC} ->`, e?.message ?? String(e));
}
