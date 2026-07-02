// Thin client for the local `strkd` wallet companion (JSON-RPC over loopback HTTP).
// It holds keys, signs, and bundles the SNIP-36 prover; every sensitive call prompts
// the human. This module is generic — it knows nothing about the framework or counter.
//
// Discover the base URL from the companion (GET /) and pass it + a persisted token in.

export const SN_SEPOLIA = "0x534e5f5345504f4c4941";
const CLIENT = "confidential-shard-orchestrator";

export class Strkd {
  constructor(private url: string, private token?: string) {}

  private async rpc(method: string, params: unknown, auth = true): Promise<any> {
    const headers: Record<string, string> = { "Content-Type": "application/json", "X-Companion-Client": CLIENT };
    if (auth && this.token) headers["Authorization"] = `Bearer ${this.token}`;
    const res = await fetch(this.url, { method: "POST", headers, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
    const j: any = await res.json();
    if (j.error) throw Object.assign(new Error(j.error.message), { code: j.error.code, details: j.error.data });
    return j.result;
  }

  getStatus = () => this.rpc("companion_getStatus", {}, false);

  async pair(name = CLIENT): Promise<{ client_id: string; token: string }> {
    const r = await this.rpc("companion_requestPairing", { name, kind: "agent" }, false);
    this.token = r.token;
    return r;
  }

  createAccount = (label?: string) => this.rpc("companion_createAgentAccount", { label });

  requestFunding = (recipient: string, amountFri: string, chainId = SN_SEPOLIA) =>
    this.rpc("companion_requestFunding", { amount: amountFri, recipient, submit: true, chainId });

  deployAccount = (account: string, chainId = SN_SEPOLIA) =>
    this.rpc("companion_deployAccount", { account, submit: true, chainId });

  /** Declare a class. `contractClass` must be RPC-ready (see rpc.rpcContractClass). */
  declare = (p: { account: string; classHash: string; compiledClassHash: string; contractClass: any; resourceBounds: ResourceBounds; nonce: string; chainId?: string }) =>
    this.rpc("wallet_addDeclareTransaction", {
      account_address: p.account, class_hash: p.classHash, compiled_class_hash: p.compiledClassHash,
      contract_class: p.contractClass, resource_bounds: p.resourceBounds, nonce: p.nonce, submit: true, chainId: p.chainId ?? SN_SEPOLIA,
    });

  /** Sign + prove a virtual tx (Tx A) in one step. resource_bounds REQUIRED (never estimate). */
  signAndProve = (p: { account: string; calls: Call[]; resourceBounds: ResourceBounds; nonce: string; blockNumber: number; chainId?: string; label?: string }) =>
    this.rpc("companion_signAndProve", {
      account_address: p.account, calls: p.calls, resource_bounds: p.resourceBounds,
      nonce: p.nonce, block_number: p.blockNumber, chainId: p.chainId ?? SN_SEPOLIA, label: p.label,
    });

  proveStatus = (jobId: string) => this.rpc("companion_proveStatus", { job_id: jobId });

  async waitProof(jobId: string, tries = 60, intervalMs = 5000): Promise<{ proof: string; proof_facts: string[]; l2_to_l1_messages: { payload: string[] }[] }> {
    for (let i = 0; i < tries; i++) {
      const s = await this.proveStatus(jobId);
      if (s.status === "succeeded") return s.result;
      if (s.status === "failed") throw new Error(`prove failed: ${JSON.stringify(s.error)}`);
      await new Promise((r) => setTimeout(r, intervalMs));
    }
    throw new Error("prove timed out");
  }

  /** Broadcast a (possibly proof-carrying) invoke. resource_bounds REQUIRED when proof-carrying. */
  addInvoke = (p: { account: string; calls: Call[]; resourceBounds: ResourceBounds; proof?: string; proofFacts?: string[]; nonce?: string; chainId?: string }) =>
    this.rpc("wallet_addInvokeTransaction", {
      account_address: p.account, calls: p.calls, resource_bounds: p.resourceBounds,
      proof: p.proof, proof_facts: p.proofFacts, nonce: p.nonce, submit: true, chainId: p.chainId ?? SN_SEPOLIA,
    });
}

export type Call = { contract_address: string; entry_point_selector: string; calldata: string[] };
export type ResourceBounds = {
  l1_gas: { max_amount: string; max_price_per_unit: string };
  l2_gas: { max_amount: string; max_price_per_unit: string };
  l1_data_gas: { max_amount: string; max_price_per_unit: string };
};

export const hex = (n: bigint) => "0x" + n.toString(16);
