// The pluggable execution backend — the seam between the framework SDK and whoever
// holds keys, runs the SNIP-36 prover, and talks to the chain.
//
// The `Shard` handle (./shard.ts) is written entirely against this interface, so it never
// knows whether it is driving the strkd wallet companion, a raw starknet.js account +
// self-hosted prover, or a test double. The shipped reference implementation is
// `StrkdBackend` (./strkd-backend.ts); write another by implementing these five methods.
//
// The backend OWNS everything prover/signer-specific: nonce selection, reference-block
// choice, and resource bounds. In particular it MUST NOT fee-estimate the virtual /
// proof-carrying transactions (that would leak private calldata to an RPC node) — it sets
// `resource_bounds` manually. Keeping that policy behind this interface is the whole point.

import type { Call } from "./encoding.ts";

/** What a successful prove step yields — the proof plus the one L2->L1 message it emitted. */
export type ProofResult = {
  /** Base64 stwo proof, passed verbatim to `apply`. */
  proof: string;
  /** proof_facts felts (hex strings), passed verbatim to `apply`. */
  proofFacts: string[];
  /** The single L2->L1 message payload = Serde(PublicMessage); decode with `decodePublicMessage`. */
  l2Payload: Array<string | bigint>;
};

/**
 * The five capabilities the shard lifecycle needs. Implementations encapsulate all
 * signing/proving/RPC detail; the generic driver only ever calls these.
 */
export interface ShardBackend {
  /**
   * Tx A — sign + prove a virtual `transition` call off-chain against a reference block.
   * `calldata` is the framework's `transition(...)` calldata (build it with
   * `transitionCalldata`). MUST set resource bounds manually (never fee-estimate).
   * `label` is an optional human-facing tag for approval prompts / prover jobs.
   */
  prove(contract: bigint, calldata: string[], label?: string): Promise<ProofResult>;

  /**
   * Tx B — broadcast the proof-carrying `apply_transition(msg)`. `calldata` is built with
   * `applyTransitionCalldata`; `proof`/`proofFacts` come straight from `prove`. Returns the
   * transaction hash.
   */
  apply(contract: bigint, calldata: string[], proof: string, proofFacts: string[]): Promise<string>;

  /**
   * A plain (proofless) invoke of one or more calls — used for `consume` (Tx C), `deposit`,
   * `register_intent`, and UDC deploy. Returns the transaction hash.
   */
  invoke(calls: Call[]): Promise<string>;

  /** Read the shard's current anchored `root` (a view call). */
  getRoot(contract: bigint): Promise<bigint>;

  /** Block until a transaction hash reaches finality; reject if it reverted. */
  waitForTx(txHash: string): Promise<string>;
}
