// The `Shard<State, Action>` handle — the high-level object app authors drive.
//
// It wraps a deployed ConfidentialShard at a fixed address, a typed `Logic`, and a
// `ShardBackend`, and owns the confidential state (the secret-holder's knowledge). One
// method — `transition(action)` — runs the entire SNIP-36 lifecycle:
//
//   prove (Tx A) -> off-chain pre-check -> apply_transition (Tx B) -> verify root
//                -> consume the outbox bundle if the logic emitted actions (Tx C)
//
// and advances the local state (with a freshly rotated salt). Deploy a new shard with
// `deployShard`, or re-attach to one you already deployed with `attachShard` (resume
// without redeploying). The framework encodings live in ./encoding.ts; this file adds no
// new wire format — it only sequences the calls.

import { hash as snhash } from "starknet";
import {
  commit, hex,
  transitionCalldata, applyTransitionCalldata, consumeCalldata,
  depositCalldata, registerIntentCalldata, shardConstructorCalldata,
  checkProof,
  type Call, type ShardState,
} from "./encoding.ts";
import type { Logic } from "./logic.ts";
import type { ShardBackend } from "./backend.ts";

/** Sepolia Universal Deployer Contract (same address on mainnet). */
export const UDC = "0x041a78e741e5af2fec34b695679bc6891742439f7afb8484ecd7766661ad02bf";

/** Per-shard genesis knobs (all default OFF — see shardConstructorCalldata). */
export type ShardGates = {
  /** apply-time reference-age bound in blocks; 0 = rely only on the protocol bound. */
  freshnessWindow?: bigint;
  /** ERC-20 charged by `register_intent`; 0 address = intents are free. */
  intentFeeToken?: bigint;
  /** intent fee amount (with `intentFeeToken`). */
  intentFeeAmount?: bigint;
};

/** Compute the genesis ShardState + root for a logic and its initial typed state (offline).
 *  v5: no framework salt — a hiding logic keeps its blinding `seed` inside `initial`. */
export function genesisOf<S, A>(logic: Logic<S, A>, initial: S): { state: ShardState; root: bigint } {
  const state: ShardState = { logicClassHash: logic.logicClassHash, appState: logic.encodeState(initial) };
  return { state, root: commit(state) };
}

/** Deterministic UDC address for a class + genesis root + deploy salt (unique=0). */
export function shardAddress(frameworkClassHash: bigint, deploySalt: bigint, genesisRoot: bigint, gates: ShardGates = {}): bigint {
  const ctor = shardConstructorCalldata({ genesisRoot, ...gates });
  return BigInt(snhash.calculateContractAddressFromHash(hex(deploySalt), hex(frameworkClassHash), ctor, 0));
}

export class Shard<State, Action> {
  private readonly backend: ShardBackend;
  readonly logic: Logic<State, Action>;
  readonly address: bigint;
  private cur: ShardState;

  constructor(backend: ShardBackend, logic: Logic<State, Action>, address: bigint, initial: ShardState) {
    this.backend = backend;
    this.logic = logic;
    this.address = address;
    this.cur = initial;
  }

  /** Typed view of the current confidential app-state (the secret-holder's knowledge). */
  get state(): State { return this.logic.decodeState(this.cur.appState); }

  /** Off-chain mirror of the current committed root. */
  get root(): bigint { return commit(this.cur); }

  /** The raw ShardState — persist this (plus `address`) to resume later via `attachShard`. */
  get shardState(): ShardState { return this.cur; }

  /** The chain's view of the anchored root (should equal `root` when in sync). */
  onchainRoot(): Promise<bigint> { return this.backend.getRoot(this.address); }

  /**
   * Run one transition end-to-end. Computes the successor state off-chain (rotating the
   * salt), proves it, pre-checks the proof, applies it, verifies the on-chain root, and —
   * if the logic emitted `actions` — consumes the outbox bundle. On success advances the
   * local state and returns the new root plus any public outputs/actions.
   */
  async transition(action: Action): Promise<{ root: bigint; state: State; outputs: bigint[]; actions: number }> {
    const prevTyped = this.logic.decodeState(this.cur.appState);
    const oldRoot = commit(this.cur);

    // Successor state (off-chain mirror): next app_state, possibly-upgraded logic. v5: no
    // framework salt — blinding, if any, is carried inside app_state by the logic's `next`.
    const nextClass = this.logic.nextClassHash?.(prevTyped, action, this.cur.logicClassHash) ?? this.cur.logicClassHash;
    const nextState: ShardState = {
      logicClassHash: nextClass,
      appState: this.logic.encodeState(this.logic.next(prevTyped, action)),
    };
    const expectedNewRoot = commit(nextState);

    // Tx A: prove the virtual transition.
    const publicInput = this.logic.buildPublicInput(action);
    const proof = await this.backend.prove(this.address, transitionCalldata(publicInput, this.cur), this.logic.name);

    // Off-chain gate: proof_facts + message hash + roots, before spending a broadcast.
    const check = checkProof({
      proofFacts: proof.proofFacts, l2Payload: proof.l2Payload,
      contractAddress: this.address, expectedOldRoot: oldRoot, expectedNewRoot,
    });
    if (!check.ok) throw new Error(`proof pre-check failed: ${check.reasons.join("; ")}`);
    const msg = check.msg;

    // Tx B: apply_transition with the proof attached.
    const applyTx = await this.backend.apply(this.address, applyTransitionCalldata(msg), proof.proof, proof.proofFacts);
    await this.backend.waitForTx(applyTx);
    await this.confirmRoot(msg.newRoot, oldRoot);

    // Tx C: if the logic emitted actions, apply_transition RECORDED them to the outbox
    // keyed by new_root; push the bundle through (permissionless, one-shot, no proof).
    if (msg.actions.length > 0) {
      const consumeCall: Call = { contract_address: hex(this.address), entry_point_selector: "consume", calldata: consumeCalldata(msg.newRoot, msg.actions) };
      const consumeTx = await this.backend.invoke([consumeCall]);
      await this.backend.waitForTx(consumeTx);
    }

    this.cur = nextState;
    return { root: msg.newRoot, state: this.state, outputs: msg.outputs, actions: msg.actions.length };
  }

  /**
   * Poll the anchored root until it reflects `expected`, tolerating the propagation lag of
   * a read RPC that trails the node the backend broadcast through (a single immediate read
   * races that lag). Throws if the root settles on neither `expected` nor the prior `prev`
   * (a genuine CAS mismatch), or never advances within the window.
   */
  private async confirmRoot(expected: bigint, prev: bigint, tries = 24, intervalMs = 5000): Promise<void> {
    for (let i = 0; i < tries; i++) {
      const onchain = await this.backend.getRoot(this.address);
      if (onchain === expected) return;
      if (onchain !== prev) throw new Error(`unexpected root after apply: ${hex(onchain)} (expected ${hex(expected)})`);
      await new Promise((r) => setTimeout(r, intervalMs));
    }
    throw new Error(`root did not advance to ${hex(expected)} within ${(tries * intervalMs) / 1000}s`);
  }

  /**
   * Deposit ERC-20 into the shard (v4 inbox), trustlessly attributed. Requires a prior
   * `approve(shard, amount)` on the token by `token`'s holder. Does NOT change the root —
   * the logic observes the inbox entry on a later transition (proven read).
   */
  async deposit(token: bigint, amount: bigint, note: bigint): Promise<string> {
    const call: Call = { contract_address: hex(this.address), entry_point_selector: "deposit", calldata: depositCalldata(token, amount, note) };
    const tx = await this.backend.invoke([call]);
    await this.backend.waitForTx(tx);
    return tx;
  }

  /** File an uninterpreted intent (e.g. an exit request) for the logic to observe (v4 inbox). */
  async registerIntent(payload: bigint[]): Promise<string> {
    const call: Call = { contract_address: hex(this.address), entry_point_selector: "register_intent", calldata: registerIntentCalldata(payload) };
    const tx = await this.backend.invoke([call]);
    await this.backend.waitForTx(tx);
    return tx;
  }
}

/**
 * Re-attach to an already-deployed shard whose state you know (resume without redeploying).
 * `state` is the confidential ShardState you persisted from `shard.shardState`.
 */
export function attachShard<S, A>(backend: ShardBackend, logic: Logic<S, A>, address: bigint, state: ShardState): Shard<S, A> {
  return new Shard(backend, logic, address, state);
}

/**
 * Deploy a fresh shard for `logic` at genesis `initial` and return a ready `Shard` handle.
 * Commits the genesis state off-chain, deploys ConfidentialShard(genesis_root, gates...) via
 * the UDC, waits for finality, and verifies the on-chain root matches. v5: genesis blinding,
 * if any, lives inside `initial` (the logic's `seed` field); `deploySalt` only affects the
 * deterministic address.
 *
 * PREREQUISITE: the framework class AND the logic class must already be declared — the
 * prover `library_call`s the logic by class hash.
 */
export async function deployShard<S, A>(opts: {
  backend: ShardBackend;
  frameworkClassHash: bigint;
  logic: Logic<S, A>;
  initial: S;
  deploySalt: bigint;
  gates?: ShardGates;
}): Promise<{ shard: Shard<S, A>; address: bigint; genesisRoot: bigint; txHash: string }> {
  const { backend, frameworkClassHash, logic, initial, deploySalt, gates = {} } = opts;
  const { state, root: genesisRoot } = genesisOf(logic, initial);

  const ctor = shardConstructorCalldata({ genesisRoot, ...gates });
  const address = shardAddress(frameworkClassHash, deploySalt, genesisRoot, gates);
  const deployCall: Call = {
    contract_address: UDC,
    entry_point_selector: "deployContract",
    calldata: [hex(frameworkClassHash), hex(deploySalt), "0x0", hex(BigInt(ctor.length)), ...ctor],
  };
  const txHash = await backend.invoke([deployCall]);
  await backend.waitForTx(txHash);

  const onchain = await backend.getRoot(address);
  if (onchain !== genesisRoot) throw new Error(`genesis root mismatch after deploy: ${hex(onchain)} != ${hex(genesisRoot)}`);

  return { shard: new Shard(backend, logic, address, state), address, genesisRoot, txHash };
}
