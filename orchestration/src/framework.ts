// Generic SDK for the confidential shard framework (ConfidentialShard).
//
// This module is LOGIC-AGNOSTIC. It encodes the framework's on-chain serialization
// and commitment exactly as the Cairo does, so any logic/state can be driven through
// it — the counter (see ./examples/counter.ts) is just one example. The encodings
// here MUST stay byte-identical to src/framework.cairo and src/interfaces.cairo.

import { hash } from "starknet";
import { randomBytes } from "node:crypto";

export const MSG_TO_ADDRESS = 0n;
export const PROOF_FACTS_N_MSG_INDEX = 7;
export const PROOF_FACTS_MSG_HASH_INDEX = 8;

/** The full confidential state. `appState` is opaque to the framework. */
export type ShardState = {
  logicClassHash: bigint;
  appState: bigint[];
  salt: bigint;
};

/** The public claim carried in the L2->L1 message and re-supplied on-chain. */
export type PublicMessage = {
  oldRoot: bigint;
  newRoot: bigint;
  outputs: bigint[];
};

const toFelt = (x: bigint) => "0x" + x.toString(16);
const felts = (xs: bigint[]) => xs.map(toFelt);

/**
 * root = poseidon([logic_class_hash, app_state.len, ...app_state, salt]).
 * Mirrors ConfidentialShard::commit — the length prefix is required.
 * (starknet.js computePoseidonHashOnElements == Cairo poseidon_hash_span, verified on Sepolia.)
 */
export function commit(s: ShardState): bigint {
  const data = [s.logicClassHash, BigInt(s.appState.length), ...s.appState, s.salt];
  return BigInt(hash.computePoseidonHashOnElements(data));
}

/**
 * Calldata for `transition(public_input, private_input: ShardState, new_salt)`.
 * Serde(Array)=[len,...elems]; Serde(ShardState)=[logic_class_hash,len,...app_state,salt];
 * then the fresh `new_salt` for the successor state (per-transition blinding rotation).
 */
export function transitionCalldata(publicInput: bigint[], s: ShardState, newSalt: bigint): string[] {
  return felts([
    BigInt(publicInput.length), ...publicInput,
    s.logicClassHash, BigInt(s.appState.length), ...s.appState, s.salt,
    newSalt,
  ]);
}

/**
 * A fresh, high-entropy blinding salt (248-bit). The successor state MUST use a new
 * salt each transition so recovering one salt cannot deanonymize any other. Generate
 * it here (or from any CSPRNG) and keep it as the next state's `salt`.
 */
export function freshSalt(): bigint {
  return BigInt("0x" + randomBytes(31).toString("hex"));
}

/** Serde(PublicMessage) = [old_root, new_root, outputs.len, ...outputs] — the L2->L1 payload. */
export function serializePublicMessage(m: PublicMessage): bigint[] {
  return [m.oldRoot, m.newRoot, BigInt(m.outputs.length), ...m.outputs];
}

/** Calldata for `apply_transition(msg: PublicMessage)`. */
export function applyTransitionCalldata(m: PublicMessage): string[] {
  return felts(serializePublicMessage(m));
}

/** Decode a prover-returned L2->L1 message payload (= Serde(PublicMessage)) back into a PublicMessage. */
export function decodePublicMessage(payload: Array<string | bigint>): PublicMessage {
  const p = payload.map((x) => BigInt(x));
  const outLen = Number(p[2]);
  return { oldRoot: p[0], newRoot: p[1], outputs: p.slice(3, 3 + outLen) };
}

/**
 * Off-chain mirror of ConfidentialShard::compute_message_hash:
 * poseidon([from, to_address, payload.len, ...payload]) where payload = Serde(PublicMessage).
 * Use it to pre-check `proof_facts[8]` BEFORE broadcasting the verifier tx.
 */
export function computeMessageHash(fromAddress: bigint, m: PublicMessage): bigint {
  const payload = serializePublicMessage(m);
  const data = [fromAddress, MSG_TO_ADDRESS, BigInt(payload.length), ...payload];
  return BigInt(hash.computePoseidonHashOnElements(data));
}

/**
 * Validate a proof result against a locally-computed message BEFORE broadcasting Tx B.
 * Catches wrong proof_facts indices / message-hash mismatches without burning a revert.
 */
export function checkProof(args: {
  proofFacts: Array<string | bigint>;
  l2Payload: Array<string | bigint>;
  contractAddress: bigint;
  expectedOldRoot: bigint;
  expectedNewRoot: bigint;
}): { ok: boolean; msg: PublicMessage; reasons: string[] } {
  const pf = args.proofFacts.map((x) => BigInt(x));
  const msg = decodePublicMessage(args.l2Payload);
  const reasons: string[] = [];
  if (pf[PROOF_FACTS_N_MSG_INDEX] !== 1n) reasons.push(`proof_facts[7] != 1 (got ${pf[PROOF_FACTS_N_MSG_INDEX]})`);
  const h = computeMessageHash(args.contractAddress, msg);
  if (pf[PROOF_FACTS_MSG_HASH_INDEX] !== h) reasons.push(`proof_facts[8] != compute_message_hash`);
  if (msg.oldRoot !== args.expectedOldRoot) reasons.push(`old_root != expected genesis/live root`);
  if (msg.newRoot !== args.expectedNewRoot) reasons.push(`new_root != expected`);
  return { ok: reasons.length === 0, msg, reasons };
}
