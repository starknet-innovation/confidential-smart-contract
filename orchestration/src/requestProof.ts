// SSE client for the SNIP-36 proof server (`POST /prove`).
//
// The server wraps the Rust `snip36 prove virtual-os` CLI and streams `log`
// events, then a terminal `done` (with the proof) or `error` event. Proving is
// heavy: ~40-50s, ~18 GB RAM — this must run against a real backend, not a browser.

import type { BigNumberish } from "starknet";

export type ProveResult = {
  proof: string;
  proofFacts: BigNumberish[];
  l2ToL1Messages?: { payload: BigNumberish[] }[];
};

// NOTE: `tx` is the SIGNED virtual INVOKE_TXN_V3. It carries the confidential
// state in its calldata, so it goes ONLY to your own proof server — never to a
// public RPC, and never through fee estimation.
export async function requestProof(
  blockNumber: number,
  tx: unknown,
  serverUrl = process.env.PROOF_SERVER_URL ?? "http://localhost:3030",
): Promise<ProveResult> {
  const res = await fetch(`${serverUrl}/prove`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ blockNumber, tx }),
  });
  if (!res.ok || !res.body) {
    throw new Error(`proof server returned ${res.status} ${res.statusText}`);
  }

  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  let result: ProveResult | undefined;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });

    const parts = buf.split("\n\n");
    buf = parts.pop() ?? "";
    for (const msg of parts) {
      const event = msg.match(/^event: (\w+)/)?.[1];
      const data = JSON.parse(msg.match(/^data: (.+)$/m)?.[1] ?? "null");
      if (event === "log") process.stderr.write(`[prove] ${data.line ?? ""}`);
      if (event === "done") result = data as ProveResult;
      if (event === "error") {
        throw Object.assign(new Error(data.message), { code: data.code, details: data.details });
      }
    }
  }

  if (!result) throw new Error("proof server closed the stream without a `done` event");
  return result;
}
