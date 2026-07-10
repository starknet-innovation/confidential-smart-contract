// On-chain serialization + commitment for the confidential shard framework.
//
// This module is the LOGIC-AGNOSTIC core of the SDK. It encodes the framework's
// on-chain serialization and commitment exactly as the Cairo does, so any logic/state
// can be driven through it. The encodings here MUST stay byte-identical to
// src/framework.cairo and src/interfaces.cairo (verified against real Sepolia proofs).
//
// Everything here is PURE and offline — no network, no secrets. App authors rarely call
// it directly; the `Shard` handle (./shard.ts) drives it. It is exported so advanced
// callers can pre-compute roots, hashes, and calldata themselves.

import { hash } from "starknet";
import { randomBytes } from "node:crypto";

export const MSG_TO_ADDRESS = 0n;
export const PROOF_FACTS_N_MSG_INDEX = 7;
export const PROOF_FACTS_MSG_HASH_INDEX = 8;

/** felt as a 0x-hex string — the wire format for every calldata element. */
export const hex = (n: bigint) => "0x" + n.toString(16);
const felts = (xs: bigint[]) => xs.map(hex);

/** A raw Starknet call `{ contract, selector, calldata }` — the generic invoke shape. */
export type Call = { contract_address: string; entry_point_selector: string; calldata: string[] };

/** The full confidential state. `appState` is opaque to the framework. v5: no framework salt —
 *  blinding, if any, is a field the logic keeps in `appState` (see salt_kit / apps). */
export type ShardState = {
  logicClassHash: bigint;
  appState: bigint[];
};

/** A public Starknet call the shard executes (via the outbox) as a transition side effect. */
export type PublicCall = {
  to: bigint;
  selector: bigint;
  calldata: bigint[];
};

/** The public claim carried in the L2->L1 message and re-supplied on-chain. */
export type PublicMessage = {
  oldRoot: bigint;
  newRoot: bigint;
  outputs: bigint[];
  actions: PublicCall[];
};

/** Serde(Array<PublicCall>) = [len, (to, selector, calldata.len, ...calldata) per call]. */
export function serializeActions(actions: PublicCall[]): bigint[] {
  const out: bigint[] = [BigInt(actions.length)];
  for (const a of actions) {
    out.push(a.to, a.selector, BigInt(a.calldata.length), ...a.calldata);
  }
  return out;
}

/**
 * Off-chain mirror of ConfidentialShard::hash_actions = poseidon(Serde(Array<PublicCall>)).
 * Must equal the on-chain commitment stored in the outbox, so `consume` verifies against it.
 */
export function hashActions(actions: PublicCall[]): bigint {
  return BigInt(hash.computePoseidonHashOnElements(serializeActions(actions)));
}

/**
 * root = poseidon([logic_class_hash, app_state.len, ...app_state]).  v5: NO framework salt.
 * Mirrors ShardComponent::commit — the length prefix is required.
 * (starknet.js computePoseidonHashOnElements == Cairo poseidon_hash_span, verified on Sepolia.)
 */
export function commit(s: ShardState): bigint {
  const data = [s.logicClassHash, BigInt(s.appState.length), ...s.appState];
  return BigInt(hash.computePoseidonHashOnElements(data));
}

/**
 * Calldata for `transition(public_input, private_input: ShardState)` (v5 — no new_salt).
 * Serde(Array)=[len,...elems]; Serde(ShardState)=[logic_class_hash,len,...app_state].
 */
export function transitionCalldata(publicInput: bigint[], s: ShardState): string[] {
  return felts([
    BigInt(publicInput.length), ...publicInput,
    s.logicClassHash, BigInt(s.appState.length), ...s.appState,
  ]);
}

/**
 * A fresh, high-entropy 248-bit value from a CSPRNG. v5: used to generate a logic-level
 * blinding `seed` (salt_kit) at origination — shared with the parties so they can
 * reconstruct state. (No longer a per-transition framework salt.)
 */
export function freshSalt(): bigint {
  return BigInt("0x" + randomBytes(31).toString("hex"));
}

/**
 * Serde(PublicMessage) = [old_root, new_root, outputs.len, ...outputs, actions...] — the
 * L2->L1 payload. `actions...` is serializeActions() (len-prefixed list of PublicCall).
 */
export function serializePublicMessage(m: PublicMessage): bigint[] {
  return [m.oldRoot, m.newRoot, BigInt(m.outputs.length), ...m.outputs, ...serializeActions(m.actions)];
}

/** Calldata for `apply_transition(msg: PublicMessage)`. */
export function applyTransitionCalldata(m: PublicMessage): string[] {
  return felts(serializePublicMessage(m));
}

/** Calldata for `consume(entry_key, actions)` — entry_key is the recording transition's new_root. */
export function consumeCalldata(entryKey: bigint, actions: PublicCall[]): string[] {
  return felts([entryKey, ...serializeActions(actions)]);
}

const U256_LOW_MASK = (1n << 128n) - 1n;

/**
 * Constructor calldata for `ConfidentialShard(genesis_root, freshness_window,
 * intent_fee_token, intent_fee_amount: u256)` (v4). Defaults = all gates off:
 * freshness 0 (rely on the protocol's reference-age bound), intent fee 0 (free).
 * These are per-shard genesis parameters — there are no setters.
 */
export function shardConstructorCalldata(opts: {
  genesisRoot: bigint;
  freshnessWindow?: bigint;
  intentFeeToken?: bigint;
  intentFeeAmount?: bigint;
}): string[] {
  const fee = opts.intentFeeAmount ?? 0n;
  return felts([
    opts.genesisRoot,
    opts.freshnessWindow ?? 0n,
    opts.intentFeeToken ?? 0n,
    fee & U256_LOW_MASK,
    fee >> 128n,
  ]);
}

/**
 * Calldata for `deposit(token, amount: u256, note)` (v4 inbox). Requires a prior
 * ERC-20 `approve(shard, amount)` by the depositor. The framework performs the
 * transfer_from itself, so the resulting inbox entry is proof-of-arrival.
 */
export function depositCalldata(token: bigint, amount: bigint, note: bigint): string[] {
  return felts([token, amount & U256_LOW_MASK, amount >> 128n, note]);
}

/** Calldata for `register_intent(payload)` (v4 inbox; payload capped at 64 felts on-chain). */
export function registerIntentCalldata(payload: bigint[]): string[] {
  return felts([BigInt(payload.length), ...payload]);
}

/** Decode a prover-returned L2->L1 message payload (= Serde(PublicMessage)) back into a PublicMessage. */
export function decodePublicMessage(payload: Array<string | bigint>): PublicMessage {
  const p = payload.map((x) => BigInt(x));
  let i = 0;
  const oldRoot = p[i++];
  const newRoot = p[i++];
  const outLen = Number(p[i++]);
  const outputs = p.slice(i, i + outLen);
  i += outLen;
  const actLen = Number(p[i++]);
  const actions: PublicCall[] = [];
  for (let k = 0; k < actLen; k++) {
    const to = p[i++];
    const selector = p[i++];
    const cdLen = Number(p[i++]);
    const calldata = p.slice(i, i + cdLen);
    i += cdLen;
    actions.push({ to, selector, calldata });
  }
  return { oldRoot, newRoot, outputs, actions };
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
