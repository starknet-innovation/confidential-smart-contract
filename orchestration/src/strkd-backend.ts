// StrkdBackend — the reference `ShardBackend`, backed by the strkd wallet companion.
//
// It composes the raw `Strkd` JSON-RPC client (./strkd.ts, signing + prover) with the
// read-only RPC helpers (./rpc.ts), and OWNS the prover policy that must not leak into the
// generic driver: reference-block selection, virtual-tx nonce, and — critically — MANUAL
// resource bounds (never fee-estimate a virtual / proof-carrying tx, or its private
// calldata would reach an RPC node). Swap this out for a starknet.js-based backend by
// implementing the same five `ShardBackend` methods.

import { hex, type Call } from "./encoding.ts";
import type { ShardBackend, ProofResult } from "./backend.ts";
import { Strkd, type ResourceBounds } from "./strkd.ts";
import * as rpc from "./rpc.ts";

// Generous manual bounds (~2x observed). The prover enforces the account balance against
// these; the apply (proof-carrying) tx needs more L2 gas than a plain invoke. Override per
// deployment via the `bounds` constructor option if real proof sizes differ.
export type BoundsPolicy = (kind: "prove" | "apply" | "invoke") => ResourceBounds;

const defaultBounds: BoundsPolicy = (kind) => ({
  l1_gas: { max_amount: hex(60_000n), max_price_per_unit: hex(300_000_000_000_000n) },
  l2_gas: { max_amount: hex(kind === "apply" ? 120_000_000n : 50_000_000n), max_price_per_unit: hex(90_000_000_000n) },
  l1_data_gas: { max_amount: hex(20_000n), max_price_per_unit: hex(2_000_000_000_000n) },
});

export class StrkdBackend implements ShardBackend {
  private readonly strkd: Strkd;
  private readonly account: string;
  private readonly bounds: BoundsPolicy;
  private readonly chainId?: string;

  constructor(strkd: Strkd, account: string, opts: { bounds?: BoundsPolicy; chainId?: string } = {}) {
    this.strkd = strkd;
    this.account = account;
    this.bounds = opts.bounds ?? defaultBounds;
    this.chainId = opts.chainId;
  }

  async prove(contract: bigint, calldata: string[], label?: string): Promise<ProofResult> {
    // Reference block a couple behind head (avoids racing reorg/availability); the virtual
    // tx nonce MUST be the account nonce AT that block — here head is recent, so latest nonce.
    const nonce = await rpc.getNonce(this.account);
    const blockNumber = Number(await rpc.getBlockNumber()) - 2;
    const call: Call = { contract_address: hex(contract), entry_point_selector: "transition", calldata };
    const { job_id } = await this.strkd.signAndProve({
      account: this.account, calls: [call], resourceBounds: this.bounds("prove"),
      nonce, blockNumber, label, chainId: this.chainId,
    });
    const p = await this.strkd.waitProof(job_id);
    return { proof: p.proof, proofFacts: p.proof_facts, l2Payload: p.l2_to_l1_messages[0].payload };
  }

  async apply(contract: bigint, calldata: string[], proof: string, proofFacts: string[]): Promise<string> {
    const call: Call = { contract_address: hex(contract), entry_point_selector: "apply_transition", calldata };
    const { transaction_hash } = await this.strkd.addInvoke({
      account: this.account, calls: [call], resourceBounds: this.bounds("apply"),
      proof, proofFacts, chainId: this.chainId,
    });
    return transaction_hash;
  }

  async invoke(calls: Call[]): Promise<string> {
    const { transaction_hash } = await this.strkd.addInvoke({
      account: this.account, calls, resourceBounds: this.bounds("invoke"), chainId: this.chainId,
    });
    return transaction_hash;
  }

  getRoot(contract: bigint): Promise<bigint> {
    return rpc.contractCall(hex(contract), "get_root").then((r) => BigInt(r[0]));
  }

  waitForTx(txHash: string): Promise<string> {
    return rpc.waitForTx(txHash);
  }
}
